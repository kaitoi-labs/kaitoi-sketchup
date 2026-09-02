require 'json'
require 'securerandom'
require 'time'

require_relative '../settings'
require_relative '../history'
require_relative '../render'
require_relative '../mcp/client'

module Kaitoio
  module Agent
    # Drives one Agent conversation.
    #
    # The panel is not an LLM: each user message becomes a Kaitoi MCP tool
    # call (`run_node_by_search`), and the MCP server chooses the node. The
    # chat log shows the tool traffic, so what happened is always visible.
    #
    # Image flow -- MCP's upload_file imports a *public URL*, so a viewport
    # capture goes: REST upload -> signed download URL -> MCP upload_file
    # -> a Kaitoi filename usable as a node input.
    module Session
      module_function

      def mcp
        @mcp ||= Kaitoio::Mcp::Client.new
      end

      def reset!
        @mcp = nil
        @attached = nil
        @tool_names = nil
        @image_input_name = nil
      end

      def attached
        @attached
      end

      # The server's tool set is the authority; the published README lists a
      # slightly different set, so confirm what is actually offered.
      RUN_TOOL = 'run_node_by_search'.freeze

      def tool_names
        @tool_names ||= mcp.tools.map { |t| t['name'] }
      end

      def ensure_run_tool!
        return true if tool_names.include?(RUN_TOOL)
        raise Kaitoio::Error.new(
          "This MCP server does not expose #{RUN_TOOL}. Available run tools: " \
          "#{tool_names.grep(/run/).join(', ')}"
        )
      end

      def status
        mcp.ensure_initialized!
        names = tool_names
        { 'ok'        => true,
          'server'    => mcp.server_info,
          'url'       => mcp.url,
          'toolCount' => names.length,
          'canRun'    => names.include?(RUN_TOOL) }
      end

      # ---- attaching the viewport ------------------------------------

      # Returns the Kaitoi filename MCP nodes can consume.
      def attach_capture(local_path)
        uploaded = Kaitoio::Render.files.upload(local_path)
        info     = Kaitoio::Render.files.download_url(uploaded['fileId'], expires_in_seconds: 3600)
        url      = info['url'] || info['downloadUrl']
        raise Kaitoio::Error.new('No signed URL for the capture') unless url

        res  = mcp.call_tool('upload_file', { 'url' => url, 'extension' => '.png' })
        name = extract_filename(res)
        raise Kaitoio::Error.new("MCP upload_file returned no filename: #{res['text'][0, 200]}") unless name

        @attached = name
        Kaitoio.log("agent attached capture as #{name}")
        name
      end

      def extract_filename(res)
        s = res['structured'] || {}
        s['filename'] || s['file'] || s['name'] ||
          (s['data'].is_a?(Hash) ? s['data']['filename'] : nil) ||
          res['text'].to_s[/[0-9a-f]{16,}\.[A-Za-z0-9]{2,5}/]
      end

      # ---- the turn --------------------------------------------------

      # Returns a Hash the panel renders:
      #   { kind: 'result' | 'cost' | 'pending' | 'error', ... }
      def ask(text, use_capture: true, confirm_cost: false, idempotency_key: nil)
        raise Kaitoio::Error.new('Say something first') if text.to_s.strip.empty?
        mcp.ensure_initialized!
        ensure_run_tool!

        key  = idempotency_key || SecureRandom.uuid
        args = { 'query' => text.to_s, 'wait_seconds' => 25, 'idempotency_key' => key }
        args['confirm_cost'] = true if confirm_cost
        args['inputs'] = { image_input_name => @attached } if use_capture && @attached && image_input_name

        res = mcp.call_tool(RUN_TOOL, args)
        interpret(res, text, key, use_capture)
      end

      # MCP tells us which input it wanted; bind the capture to that name and
      # retry rather than guessing a pin name up front.
      def interpret(res, text, key, use_capture)
        body = res['structured'] || {}
        blob = "#{res['text']} #{body.to_json rescue ''}"

        if blob.include?('COST_CONFIRMATION_REQUIRED')
          return { 'kind' => 'cost', 'preview' => body['costPreview'] || body,
                   'idempotencyKey' => key, 'text' => res['text'] }
        end

        if blob.include?('MISSING_REQUIRED_INPUTS') && use_capture && @attached
          name = missing_input_name(body, res['text'])
          if name && name != image_input_name
            @image_input_name = name
            Kaitoio.log("agent retrying with capture bound to '#{name}'")
            retry_args = { 'query' => text.to_s, 'wait_seconds' => 25,
                           'idempotency_key' => SecureRandom.uuid,
                           'inputs' => { name => @attached } }
            return interpret(mcp.call_tool(RUN_TOOL, retry_args), text, key, false)
          end
        end

        execution_id = body['executionId'] || body['execution_id']
        status       = (body['status'] || '').to_s

        if execution_id && !%w[succeeded failed canceled].include?(status)
          return { 'kind' => 'pending', 'executionId' => execution_id,
                   'status' => status, 'text' => res['text'] }
        end

        { 'kind' => 'result', 'executionId' => execution_id, 'status' => status,
          'text' => res['text'], 'body' => body }
      end

      def missing_input_name(body, text)
        candidates = body['missingInputs'] || body['missing'] || body['requiredInputs']
        if candidates.is_a?(Array) && !candidates.empty?
          first = candidates.first
          return first.is_a?(Hash) ? (first['name'] || first['input']) : first.to_s
        end
        text.to_s[/["']([A-Za-z_][A-Za-z0-9_]*)["']\s*(?:is )?required/, 1]
      end

      def image_input_name
        @image_input_name
      end

      def poll(execution_id)
        mcp.call_tool('get_graph_run_status', { 'execution_id' => execution_id })
      end

      # ---- results ---------------------------------------------------

      # Resolve an execution's media to signed URLs, download the first one.
      def collect_output(execution_id, prompt)
        res  = mcp.call_tool('get_displayable_outputs', { 'execution_id' => execution_id })
        body = res['structured'] || {}
        urls = %w[image_urls video_urls audio_urls file_urls].flat_map { |k| Array(body[k]) }
        urls = urls.map { |u| u.is_a?(Hash) ? (u['url'] || u['href']) : u }.compact
        return { 'kind' => 'text', 'text' => res['text'] } if urls.empty?

        url  = urls.first
        ext  = File.extname(URI.parse(url).path.to_s)
        ext  = '.png' if ext.empty?
        dest = File.join(Kaitoio::Settings.download_dir, "kaitoi_agent_#{Time.now.to_i}#{ext}")
        got  = Kaitoio::Render.client.download_to(url, dest)

        entry = {
          'at'          => Time.now.utc.iso8601,
          'kind'        => 'agent',
          'label'       => 'MCP',
          'prompt'      => prompt,
          'runId'       => execution_id,
          'contentType' => got['contentType'],
          'path'        => got['path']
        }
        Kaitoio::History.add(entry)
        { 'kind' => 'media', 'entry' => entry, 'text' => res['text'], 'urlCount' => urls.length }
      rescue Kaitoio::Error => e
        Kaitoio.log_error('agent output collection failed', e)
        { 'kind' => 'text', 'text' => "Run finished but outputs could not be resolved: #{e}" }
      end
    end
  end
end
