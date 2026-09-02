require 'fileutils'
require 'tmpdir'
require 'securerandom'

require_relative 'settings'
require_relative 'history'
require_relative 'api/client'
require_relative 'api/files'
require_relative 'api/runs'
require_relative 'api/node_types'
require_relative 'api/templates'
require_relative 'graph/builder'

module Kaitoio
  # Everything between "the user pressed Generate" and "a file landed in
  # ~/KaitoioDownloads": viewport capture, pin binding, run submission,
  # result download.
  #
  # Nothing here blocks on a run finishing. Callers submit, then poll from a
  # UI.start_timer tick (see ui/dialog.rb).
  module Render
    module_function

    # ---- API handles (rebuilt each call so Preferences edits take effect) --

    def client
      Kaitoio::Api::Client.new
    end

    def files;      Kaitoio::Api::Files.new(client);     end
    def runs;       Kaitoio::Api::Runs.new(client);      end
    def node_types; Kaitoio::Api::NodeTypes.new(client); end
    def templates;  Kaitoio::Api::Templates.new(client); end

    # ---- capture ---------------------------------------------------------

    # Write the active viewport to a PNG, longest edge capped at max_edge so
    # we don't upload a 4K frame for a preview run.
    def capture_view(max_edge: nil, dest: nil)
      model = Sketchup.active_model
      raise Kaitoio::Error.new('No active SketchUp model') unless model

      view = model.active_view
      max_edge ||= Kaitoio::Settings.capture_max_edge
      w, h = scaled_size(view.vpwidth, view.vpheight, max_edge)

      dest ||= File.join(Dir.tmpdir, "kaitoi_capture_#{Time.now.to_i}_#{SecureRandom.hex(3)}.png")
      FileUtils.mkdir_p(File.dirname(dest))
      view.write_image(filename: dest, width: w, height: h, antialias: true, transparent: false)
      raise Kaitoio::Error.new('Viewport capture produced no file') unless File.file?(dest)

      Kaitoio.log("captured viewport #{w}x#{h} -> #{dest}")
      { 'path' => dest, 'width' => w, 'height' => h }
    end

    def scaled_size(vw, vh, max_edge)
      vw = vw.to_i
      vh = vh.to_i
      return [max_edge, max_edge] if vw <= 0 || vh <= 0

      longest = [vw, vh].max
      return [vw, vh] if longest <= max_edge

      scale = max_edge.to_f / longest
      [(vw * scale).round, (vh * scale).round]
    end

    # ---- pin binding -----------------------------------------------------

    # Pin dataTypes that carry a fileId rather than a literal value.
    # Confirmed against /node-types: image, 3d, audio, file, archive, splat.
    FILE_PIN_TYPES = %w[file image video audio 3d archive splat model].freeze

    # A viewport capture is a PNG. It may only be bound to a pin that accepts
    # an image; a `3d` pin wants a mesh, and feeding it a screenshot fails
    # downstream inside the node rather than here.
    CAPTURE_PIN_TYPES = %w[image file].freeze

    # List endpoints wrap results as { "data" => [...], "nextCursor" =>, "hasMore" => }
    def unwrap(res)
      return [] if res.nil?
      return res if res.is_a?(Array)
      res['data'] || res['items'] || []
    end

    # Normalize whatever shape /node-types/{type} returns into
    # [{ 'name' =>, 'type' =>, 'default' => }, ...]
    def input_pins(schema)
      raw = schema['inputs'] || schema['inputPins'] || []
      list = raw.is_a?(Hash) ? raw.map { |name, v| (v || {}).merge('name' => name) } : raw
      list.map do |pin|
        next nil unless pin.is_a?(Hash)
        { 'name'  => (pin['name'] || pin['id']).to_s,
          'label'  => pin['label'].to_s,
          'type'   => (pin['type'] || pin['dataType']).to_s.downcase,
          'default' => pin['default'] }
      end.compact.reject { |p| p['name'].empty? }
    end

    # Strictly by declared dataType. A name-based fallback is unsafe:
    # "num_images" matches /image/ but is an int, and binding a fileId into
    # it fails inside the node with `invalid literal for int()`.
    def file_pin(pins)
      pins.find { |p| FILE_PIN_TYPES.include?(p['type']) }
    end

    # The pin a viewport capture may legitimately fill. Prefers a true image
    # pin over a generic file pin.
    def capture_pin(pins)
      pins.find { |p| p['type'] == 'image' } ||
        pins.find { |p| p['type'] == 'file' }
    end

    # Only bind the prompt to a pin that actually reads like free text.
    # Falling back to "first string pin" would happily stuff a prompt into
    # an enum such as inputFileType.
    PROMPT_PIN = /prompt|caption|description|instruction|(^|_)text($|_)/i

    def prompt_pin(pins)
      pins.select { |p| %w[string text].include?(p['type']) }
          .find { |p| p['name'] =~ PROMPT_PIN || p['label'].to_s =~ PROMPT_PIN }
    end

    # ---- node runs -------------------------------------------------------

    # Upload the capture, build a one-node inline graph, submit a run.
    # Returns the accepted run record (status is not terminal yet).
    def start_node_run(node_type:, prompt: nil, image_path: nil)
      raise Kaitoio::Error.new('No node type selected') if node_type.to_s.empty?

      schema = node_types.get(node_type)
      pins   = input_pins(schema)

      builder = Kaitoio::Graph::Builder.new
      node_id = builder.add_node(type: node_type, title: schema['title'] || node_type)

      pin = image_path ? capture_pin(pins) : nil
      if pin
        uploaded = files.upload(image_path)
        builder.set_file_input(node_id, pin['name'], uploaded['fileId'])
        Kaitoio.log("bound #{uploaded['fileId']} -> #{node_type}.#{pin['name']} (#{pin['type']})")
      elsif image_path
        other = file_pin(pins)
        if other
          # e.g. Hunyuan 3D Smart Topology wants a mesh on a `3d` pin; sending
          # the PNG capture there fails downstream inside the node.
          raise Kaitoio::Error.new(
            "#{node_type} expects #{other['type']} on '#{other['name']}', not a viewport image. " \
            'Pick an image-input node for viewport renders.'
          )
        end
        # Text-to-image nodes declare no file input; run prompt-only.
        Kaitoio.log("node #{node_type} takes no file input; capture not sent", 'WARN')
      end

      if prompt && !prompt.to_s.strip.empty?
        pin = prompt_pin(pins)
        if pin
          builder.set_node_input(node_id, pin['name'], prompt.to_s, type: 'string')
          Kaitoio.log("bound prompt -> #{node_type}.#{pin['name']}")
        else
          Kaitoio.log("node #{node_type} has no text pin; prompt ignored", 'WARN')
        end
      end

      Kaitoio::Settings.update('last_node_type' => node_type)
      runs.create(graph: builder.to_graph, target_node_ids: [node_id])
    end

    # ---- template runs ---------------------------------------------------

    # Templates declare their inputs, so binding is explicit instead of
    # guessed from graph pins.
    def start_template_run(template_id:, endpoint_id: nil, prompt: nil, image_path: nil)
      endpoint_id ||= first_endpoint_id(template_id)
      raise Kaitoio::Error.new('Template has no active endpoint') unless endpoint_id

      docs   = templates.docs(template_id, endpoint_id)
      fields = declared_inputs(docs)
      inputs = {}

      if image_path
        field = fields.find { |f| f['type'] == 'image' } ||
                fields.find { |f| f['type'] == 'file' }
        if field.nil? && (other = fields.find { |f| file_field?(f) })
          raise Kaitoio::Error.new(
            "This template expects #{other['type']} on '#{other['name']}', not a viewport image."
          )
        end
        if field
          uploaded = files.upload(image_path)
          inputs[field['name']] = { 'type' => 'file', 'fileId' => uploaded['fileId'] }
          Kaitoio.log("bound #{uploaded['fileId']} -> #{field['name']}")
        else
          Kaitoio.log('template endpoint takes no file input; capture not sent', 'WARN')
        end
      end

      # Primitive inputs are sent as bare scalars, not typed pin objects.
      # Anything left unset falls back to the endpoint's declared default.
      if prompt && !prompt.to_s.strip.empty?
        field = fields.find { |f| f['kind'] != 'file' && %w[string text].include?(f['type']) }
        if field
          inputs[field['name']] = prompt.to_s
          Kaitoio.log("bound prompt -> #{field['name']}")
        else
          Kaitoio.log('template endpoint declares no text input; prompt ignored', 'WARN')
        end
      end

      templates.create_run(template_id, endpoint_id, inputs: inputs)
    end

    def first_endpoint_id(template_id)
      ep = unwrap(templates.endpoints(template_id)).first
      ep && (ep['endpointId'] || ep['id'])
    end

    # Endpoint docs describe inputs as
    #   { name (label), fieldName (the key to send), dataType, kind, pinName }
    # `fieldName` is what the run body is keyed by -- not `name`.
    def declared_inputs(docs)
      (docs['inputs'] || []).map do |f|
        next nil unless f.is_a?(Hash)
        { 'name'  => (f['fieldName'] || f['name']).to_s,
          'label' => f['name'].to_s,
          'type'  => f['dataType'].to_s.downcase,
          'kind'  => f['kind'].to_s.downcase }
      end.compact.reject { |f| f['name'].empty? }
    end

    def file_field?(f)
      f['kind'] == 'file' || FILE_PIN_TYPES.include?(f['type'])
    end

    # ---- results ---------------------------------------------------------

    # Pull the first file output of a finished run down to disk and record it
    # in Generations.
    def download_output(run, label: nil, prompt: nil, kind: 'render')
      output = runs.first_file_output(run)
      return nil unless output

      dest = File.join(Kaitoio::Settings.download_dir, output_filename(output, run))
      result =
        if output['downloadUrl']
          client.download_to(output['downloadUrl'], dest)
        else
          files.download(output['fileId'], dest_path: dest)
        end

      entry = {
        'at'          => Time.now.utc.iso8601,
        'kind'        => kind,
        'label'       => label,
        'prompt'      => prompt,
        'runId'       => run['id'],
        'fileId'      => output['fileId'],
        'contentType' => output['contentType'] || result['contentType'],
        'path'        => result['path'],
        'creditsUsed' => run['creditsUsed']
      }
      Kaitoio::History.add(entry)
      Kaitoio.log("downloaded #{entry['contentType']} -> #{entry['path']}")
      entry
    end

    def output_filename(output, run)
      name = output['filename'].to_s
      return sanitize(name) unless name.empty?

      ext = extension_for(output['contentType'])
      "kaitoi_#{run['id']}#{ext}"
    end

    def extension_for(content_type)
      case content_type.to_s
      when %r{^image/png}  then '.png'
      when %r{^image/jpe?g} then '.jpg'
      when %r{^image/webp} then '.webp'
      when %r{^video/mp4}  then '.mp4'
      when %r{^video/webm} then '.webm'
      when %r{^video/}     then '.mov'
      else '.bin'
      end
    end

    def image?(content_type); content_type.to_s.start_with?('image/'); end
    def video?(content_type); content_type.to_s.start_with?('video/'); end

    def sanitize(name)
      name.gsub(/[^A-Za-z0-9._-]+/, '_')
    end

    # Open a downloaded file in the OS viewer/player. SketchUp's embedded
    # browser has no H.264 codec, so video never plays in-panel.
    def open_file(path)
      return false unless File.exist?(path)
      UI.openURL("file://#{path}")
      true
    rescue => e
      Kaitoio.log_error("could not open #{path}", e)
      false
    end
  end
end
