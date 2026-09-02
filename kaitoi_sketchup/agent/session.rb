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
        @history = []
        @allow_cost = false
      end

      def history
        @history ||= []
      end

      def allow_cost!
        @allow_cost = true
      end

      def cost_allowed?
        @allow_cost == true
      end

      # ---- conversation ----------------------------------------------

      # The chat node is asked for one JSON object so a plain greeting stays a
      # greeting. Previously every message was fed straight to
      # run_node_by_search, so "hi" came back as AMBIGUOUS_NODE_MATCH.
      SYSTEM = <<~PROMPT.freeze
        You are the Kaitoi assistant, embedded in SketchUp. The user is modelling;
        when an image is attached it is a capture of their current viewport.

        Kaitoi can generate and transform media (images, video, 3D) through its
        node library. You may ask Kaitoi to run a node when the user actually
        wants something created or transformed.

        Reply with ONE JSON object and nothing else, no code fences:
        {"reply": "<what you say to the user>", "generate": null}
        or
        {"reply": "<what you are about to do>",
         "generate": {"query": "<node capability, e.g. image to image edit>",
                      "prompt": "<prompt for that node>"}}

        Set "generate" only when the user asks to create or change media.
        For greetings, questions, or discussion about the model, use null.
        Keep "reply" short and conversational.

        Make "query" specific enough to identify one node. A bare "image to
        image" matches many nodes equally and cannot be run; name the model or
        the exact operation instead, e.g. "FLUX SRPO image to image",
        "Qwen image edit", "remove background", "image to 3D".
      PROMPT

      def chat_node
        Kaitoio::Settings.load['agent_chat_node'].to_s
      end

      # One conversational turn. Returns:
      #   { 'kind' => 'reply',   'reply' =>, 'generate' => nil|Hash }
      #   { 'kind' => 'cost',    'preview' =>, 'stage' => 'chat' }
      def chat(text, use_capture: true, confirm_cost: false)
        raise Kaitoio::Error.new('Say something first') if text.to_s.strip.empty?
        mcp.ensure_initialized!

        inputs = { 'prompt' => build_prompt(text) }
        inputs['inputImage'] = @attached if use_capture && @attached

        args = { 'node_type' => chat_node, 'inputs' => inputs,
                 'wait_seconds' => 45, 'idempotency_key' => SecureRandom.uuid }
        args['confirm_cost'] = true if confirm_cost || cost_allowed?

        res  = mcp.call_tool('run_node_by_type', args)
        body = res['structured'] || {}
        blob = "#{res['text']}"

        if blob.include?('COST_CONFIRMATION_REQUIRED')
          return { 'kind' => 'cost', 'stage' => 'chat', 'text' => text,
                   'preview' => body['costPreview'] || body }
        end

        answer = extract_text(body, res['text'])
        parsed = parse_reply(answer)

        history << { 'role' => 'user', 'text' => text.to_s }
        history << { 'role' => 'assistant', 'text' => parsed['reply'].to_s }
        trim_history

        { 'kind' => 'reply', 'reply' => parsed['reply'], 'generate' => parsed['generate'] }
      end

      def build_prompt(text)
        parts = [SYSTEM]
        unless history.empty?
          parts << '---'
          history.each do |h|
            parts << "#{h['role'] == 'user' ? 'User' : 'Assistant'}: #{h['text']}"
          end
        end
        parts << "User: #{text}"
        parts << 'Assistant:'
        parts.join("\n")
      end

      def trim_history
        keep = (Kaitoio::Settings.load['agent_history_turns'] || 8).to_i * 2
        @history = history.last(keep) if history.length > keep
      end

      # The output pin differs per node: gemini_multimodal -> analysis,
      # chatgpt -> reply, openrouter_chat -> response.
      def extract_text(body, fallback)
        outs = body['outputs']
        if outs.is_a?(Hash)
          %w[analysis reply response chat text].each do |k|
            v = outs[k]
            return v if v.is_a?(String) && !v.strip.empty?
          end
          str = outs.values.find { |v| v.is_a?(String) && !v.strip.empty? }
          return str if str
        end
        %w[text analysis reply].each do |k|
          return body[k] if body[k].is_a?(String) && !body[k].strip.empty?
        end
        fallback.to_s
      end

      # Models wrap JSON in prose or fences often enough that a strict parse
      # would drop good answers; fall back to treating it all as the reply.
      def parse_reply(answer)
        raw = answer.to_s.strip
        raw = raw.sub(/\A```(?:json)?/, '').sub(/```\z/, '').strip
        candidate = raw[/\{.*\}/m]
        if candidate
          begin
            obj = JSON.parse(candidate)
            if obj.is_a?(Hash) && obj.key?('reply')
              gen = obj['generate']
              gen = nil unless gen.is_a?(Hash) && !gen['query'].to_s.strip.empty?
              return { 'reply' => obj['reply'].to_s, 'generate' => gen }
            end
          rescue JSON::ParserError
            nil
          end
        end
        { 'reply' => raw.empty? ? '(no reply)' : raw, 'generate' => nil }
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
      def ask(text, prompt: nil, use_capture: true, confirm_cost: false, idempotency_key: nil)
        raise Kaitoio::Error.new('Say something first') if text.to_s.strip.empty?
        mcp.ensure_initialized!
        ensure_run_tool!

        key  = idempotency_key || SecureRandom.uuid
        args = { 'query' => text.to_s, 'wait_seconds' => 25, 'idempotency_key' => key }
        args['confirm_cost'] = true if confirm_cost || cost_allowed?

        inputs = {}
        inputs['prompt'] = prompt.to_s if prompt && !prompt.to_s.strip.empty?
        inputs[image_input_name] = @attached if use_capture && @attached && image_input_name
        args['inputs'] = inputs unless inputs.empty?
        @last_inputs = inputs
        @last_prompt = prompt

        res = mcp.call_tool(RUN_TOOL, args)
        interpret(res, text, key, use_capture)
      end

      # MCP tells us which input it wanted; bind the capture to that name and
      # retry rather than guessing a pin name up front.
      def interpret(res, text, key, use_capture, resolved = false)
        body = res['structured'] || {}
        blob = "#{res['text']} #{body.to_json rescue ''}"

        # The search matched several nodes equally well, so nothing ran. The
        # server hands back ranked candidates and tells us to pick one by
        # exact type -- do that instead of surfacing a wall of JSON.
        if !resolved && blob.include?('AMBIGUOUS_NODE_MATCH')
          ranked = rank_candidates(body)
          picked = ranked.first

          if picked && !confident?(picked)
            # Nothing matched semantically; let the user choose instead of
            # guessing and billing them for it.
            @pending_choice = { 'text' => text, 'prompt' => @last_prompt }
            return { 'kind' => 'choose', 'query' => body['query'] || text,
                     'candidates' => ranked.first(5).map { |c|
                       { 'nodeType' => c['nodeType'], 'title' => c['title'],
                         'category' => c['category'], 'confidence' => c['confidence'],
                         'score' => c['rankScore'] }
                     } }
          end

          if picked
            Kaitoio.log("ambiguous match for #{text.inspect}; choosing #{picked['nodeType']} " \
                        "(confidence #{picked['confidence']})")
            out = run_exact(picked['nodeType'], text, key, @last_prompt)
            return out.merge('selectedNode' => {
              'nodeType'   => picked['nodeType'],
              'title'      => picked['title'],
              'score'      => picked['rankScore'],
              'confidence' => picked['confidence'],
              'from'       => 'ambiguous'
            })
          end
        end

        # run_node_by_search may also name its pick without running it.
        if !resolved && body['selectedNode'].is_a?(Hash) && body['executionId'].nil?
          sel = body['selectedNode']
          type = sel['nodeType'] || sel['type']
          if type
            out = run_exact(type, text, key, @last_prompt)
            return out.merge('selectedNode' => { 'nodeType' => type, 'title' => sel['title'], 'from' => 'selected' })
          end
        end

        if blob.include?('COST_CONFIRMATION_REQUIRED')
          return { 'kind' => 'cost', 'preview' => body['costPreview'] || body,
                   'idempotencyKey' => key, 'text' => res['text'] }
        end

        if blob.include?('MISSING_REQUIRED_INPUTS') && use_capture && @attached
          name = missing_input_name(body, res['text'])
          if name && name != image_input_name
            @image_input_name = name
            Kaitoio.log("agent retrying with capture bound to '#{name}'")
            retry_inputs = { name => @attached }
            retry_inputs['prompt'] = @last_prompt.to_s if @last_prompt && !@last_prompt.to_s.strip.empty?
            retry_args = { 'query' => text.to_s, 'wait_seconds' => 25,
                           'idempotency_key' => SecureRandom.uuid,
                           'confirm_cost' => cost_allowed?,
                           'inputs' => retry_inputs }
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

      # Once the exact node type is known, bind inputs from its real schema
      # instead of reusing generic names. A scratch graph has no upstream
      # connections, so every required input must be supplied explicitly --
      # that is what MISSING_REQUIRED_INPUTS is complaining about.
      def inputs_for_node(node_type, prompt)
        pins = Kaitoio::Render.input_pins(Kaitoio::Render.node_types.get(node_type))
        inputs = {}

        if @attached
          pin = Kaitoio::Render.capture_pin(pins)
          inputs[pin['name']] = @attached if pin
        end

        unless prompt.to_s.strip.empty?
          pin = Kaitoio::Render.prompt_pin(pins)
          inputs[pin['name']] = prompt.to_s if pin
        end

        # Anything else the node demands and we cannot fill, reported by name
        # rather than as a generic failure.
        missing = pins.select { |p|
          p['default'].nil? && !inputs.key?(p['name']) &&
            Kaitoio::Render::FILE_PIN_TYPES.include?(p['type'])
        }.map { |p| "#{p['name']}:#{p['type']}" }

        [inputs, missing]
      rescue Kaitoio::Error => e
        Kaitoio.log("could not read schema for #{node_type}: #{e.message}", 'WARN')
        [@last_inputs || {}, []]
      end

      # Run a known node type with inputs bound from its schema.
      def run_exact(node_type, text, key, prompt)
        inputs, missing = inputs_for_node(node_type, prompt)
        if inputs.empty? && !missing.empty?
          raise Kaitoio::Error.new(
            "#{node_type} needs #{missing.join(', ')} and nothing is attached. " \
            'Capture the viewport first.'
          )
        end
        Kaitoio.log("running #{node_type} with inputs #{inputs.keys.join(', ')}")
        args = { 'node_type' => node_type, 'inputs' => inputs,
                 'wait_seconds' => 25, 'idempotency_key' => SecureRandom.uuid }
        args['confirm_cost'] = true if cost_allowed?
        res = mcp.call_tool('run_node_by_type', args)

        # Still short of inputs: say which node, what we sent, and what it
        # wants, instead of repeating the server's generic sentence.
        if "#{res['text']}".include?('MISSING_REQUIRED_INPUTS')
          body   = res['structured'] || {}
          wanted = Array(body['missingInputs'] || body['missing'] || body['requiredInputs'])
          names  = wanted.map { |m| m.is_a?(Hash) ? (m['name'] || m['input']) : m }.compact
          detail = names.empty? ? '' : " It needs: #{names.join(', ')}."
          sent   = inputs.keys.empty? ? 'nothing' : inputs.keys.join(', ')
          raise Kaitoio::Error.new(
            "#{node_type} could not run with the inputs available (sent: #{sent}).#{detail}",
            code: 'MISSING_REQUIRED_INPUTS'
          )
        end

        interpret(res, text, key, false, true)
      end

      # Candidates with rawSemanticScore == nil matched lexically only, and
      # carry a flat 0.45 confidence. Ranking on rankScore alone let one of
      # those win -- FLUX 2 Pro Outpaint was picked to "make an illustration".
      # Prefer semantically matched nodes, then confidence, then rankScore.
      CONFIDENT = 0.6

      def rank_candidates(body)
        cands = body['candidates']
        return [] unless cands.is_a?(Array)
        usable = cands.select { |c| c.is_a?(Hash) && c['nodeType'] }
        semantic = usable.reject { |c| c['rawSemanticScore'].nil? }
        pool = semantic.empty? ? usable : semantic
        pool.sort_by { |c| [-c['confidence'].to_f, -c['rankScore'].to_f] }
      end

      def best_candidate(body)
        rank_candidates(body).first
      end

      # Only auto-run when the winner is actually confident; otherwise the
      # user picks, rather than spending credits on a guess.
      def confident?(candidate)
        candidate && candidate['confidence'].to_f >= CONFIDENT
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

      # Run a node the user picked from the ambiguity list.
      def run_chosen(node_type)
        choice = @pending_choice || {}
        @pending_choice = nil
        run_exact(node_type, choice['text'].to_s, SecureRandom.uuid, choice['prompt'])
      end

      def poll(execution_id)
        mcp.call_tool('get_graph_run_status', { 'execution_id' => execution_id })
      end

      # Progress / diagnostic events for a durable execution. This tool takes
      # no cursor, so the whole tail comes back each time and new events are
      # picked out here.
      def events(execution_id, limit: 100)
        res  = mcp.call_tool('get_graph_run_events', { 'execution_id' => execution_id, 'limit' => limit })
        body = res['structured'] || {}
        list = body['events'] || body['data'] || body['items'] || []
        list.is_a?(Array) ? list : []
      rescue Kaitoio::Error => e
        Kaitoio.log("agent events unavailable: #{e.message}", 'WARN')
        []
      end

      # ---- results ---------------------------------------------------

      # Resolve an execution's media to signed URLs, download the first one.
      # get_displayable_outputs answers {"pending":true,...} while an
      # execution is still settling; that is not a result.
      def pending?(body, text)
        return true if body['pending'] == true
        status = body['status'].to_s.downcase
        return true if %w[running queued pending accepted].include?(status)
        text.to_s.include?('still running')
      end

      # Never surface a raw MCP envelope as chat; keep it short and human.
      def summarize(text)
        raw = text.to_s.strip
        begin
          json = raw[/\{.*\}/m]
          if json
            obj = JSON.parse(json)
            if obj.is_a?(Hash)
              msg = obj['message'] || obj['error'] || obj['status']
              return msg.to_s unless msg.to_s.empty?
            end
          end
        rescue JSON::ParserError
          nil
        end
        raw.length > 240 ? "#{raw[0, 240]}…" : raw
      end

      def collect_output(execution_id, prompt)
        res  = mcp.call_tool('get_displayable_outputs', { 'execution_id' => execution_id })
        body = res['structured'] || {}
        urls = %w[image_urls video_urls audio_urls file_urls].flat_map { |k| Array(body[k]) }
        urls = urls.map { |u| u.is_a?(Hash) ? (u['url'] || u['href']) : u }.compact

        # The node can finish while the execution is still settling, and this
        # tool then answers {"pending":true,"status":"running"}. That is not a
        # result -- keep waiting rather than printing the envelope as a reply.
        if urls.empty? && pending?(body, res['text'])
          return { 'kind' => 'pending', 'executionId' => execution_id }
        end
        return { 'kind' => 'text', 'text' => summarize(res['text']) } if urls.empty?

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
