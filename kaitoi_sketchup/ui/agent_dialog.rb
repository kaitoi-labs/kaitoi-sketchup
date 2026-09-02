require 'json'
require 'base64'

require_relative '../settings'
require_relative '../history'
require_relative '../render'
require_relative '../agent/session'
require_relative '../mcp/oauth'

module Kaitoio
  module Dialogs
    # "Kaitoi Agent" panel: chat on the left, viewport capture and the
    # generated result on the right.
    #
    # Same rules as the main panel -- no HTTP in JS, and long work is polled
    # from UI.start_timer rather than a background thread.
    module AgentDialog
      module_function

      HTML_DIR = File.join(File.dirname(__FILE__), 'html')

      def show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return @dialog
        end

        @dialog = UI::HtmlDialog.new(
          dialog_title:    'Kaitoi Agent',
          preferences_key: 'io.kaitoi.sketchup.agent',
          scrollable:      true,
          resizable:       true,
          width:           1120,
          height:          780,
          min_width:       720,
          min_height:      520,
          style:           UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_file(File.join(HTML_DIR, 'agent.html'))
        attach_callbacks(@dialog)
        # Surface every MCP tool call in the panel, so the user can see what
        # the agent is actually doing rather than only "generating…".
        Kaitoio::Mcp.observer = proc do |name, phase, detail|
          push('agent_tool', 'ok' => true,
               'data' => { 'tool' => name, 'phase' => phase, 'detail' => detail })
        end
        @dialog.set_on_closed do
          stop_polling
          stop_auth_pump
          Kaitoio::Mcp::OAuth.stop_listener
          Kaitoio::Mcp.observer = nil
          @dialog = nil
        end
        @dialog.show
        @dialog
      end

      def close
        stop_polling
        @dialog.close if @dialog
        @dialog = nil
      end

      def guard(channel)
        push(channel, 'ok' => true, 'data' => yield)
      rescue Kaitoio::Error => e
        Kaitoio.log_error("agent #{channel} failed", e)
        push(channel, 'ok' => false, 'error' => e.to_s, 'code' => e.code)
      rescue => e
        Kaitoio.log_error("agent #{channel} failed", e)
        push(channel, 'ok' => false, 'error' => "#{e.class}: #{e.message}")
      end

      def push(channel, payload)
        return unless @dialog
        @dialog.execute_script(
          "window.kaitoi && window.kaitoi.receive(#{JSON.generate(channel)}, #{JSON.generate(payload)});"
        )
        nil
      end

      def attach_callbacks(dialog)
        dialog.add_action_callback('agent_boot') do |_ctx|
          guard('agent_boot') do
            cfg   = Kaitoio::Settings.load
            token = cfg['mcp_token'].to_s
            { 'version'  => Kaitoio::VERSION,
              'mcpUrl'   => cfg['mcp_url'],
              # MCP is its own API: a REST key is never used here.
              'authMode' => token.empty? ? 'oauth' : 'token',
              'signedIn' => !token.empty? || Kaitoio::Mcp::OAuth.signed_in?,
              'attached' => Kaitoio::Agent::Session.attached,
              'history'  => Kaitoio::History.list.select { |h| h['kind'] == 'agent' } }
          end
        end

        dialog.add_action_callback('agent_connect') do |_ctx|
          guard('agent_connect') { Kaitoio::Agent::Session.status }
        end

        # OAuth: open the browser, then poll the loopback listener from a
        # timer. Blocking on accept would freeze SketchUp.
        dialog.add_action_callback('agent_signin') do |_ctx|
          guard('agent_signin') do
            url = Kaitoio::Mcp::OAuth.begin_sign_in
            UI.openURL(url)
            start_auth_pump
            { 'opened' => true, 'url' => url }
          end
        end

        dialog.add_action_callback('agent_signout') do |_ctx|
          guard('agent_signout') do
            Kaitoio::Mcp::OAuth.forget!
            Kaitoio::Agent::Session.reset!
            { 'signedOut' => true }
          end
        end

        dialog.add_action_callback('agent_capture') do |_ctx|
          guard('agent_capture') do
            shot = Kaitoio::Render.capture_view
            name = Kaitoio::Agent::Session.attach_capture(shot['path'])
            { 'path'     => shot['path'],
              'width'    => shot['width'],
              'height'   => shot['height'],
              'filename' => name,
              'dataUri'  => data_uri(shot['path'], 'image/png') }
          end
        end

        # A turn is a conversation first: the chat node answers, and only
        # asks for a generation when the user actually wants one.
        dialog.add_action_callback('agent_send') do |_ctx, json|
          guard('agent_send') do
            args    = parse_args(json)
            text    = args['text']
            capture = args['useCapture'] != false
            Kaitoio::Agent::Session.allow_cost! if args['allowCost'] == true

            res = Kaitoio::Agent::Session.chat(
              text, use_capture: capture, confirm_cost: args['confirmCost'] == true
            )
            next res if res['kind'] == 'cost'

            gen = res['generate']
            if gen
              run = Kaitoio::Agent::Session.ask(
                gen['query'], prompt: gen['prompt'], use_capture: capture
              )
              handle_turn(run, gen['prompt'] || text)
              res.merge('run' => run)
            else
              res
            end
          end
        end

        # The user picked a node from the ambiguity list.
        dialog.add_action_callback('agent_run_node') do |_ctx, json|
          guard('agent_send') do
            node = parse_args(json)['nodeType'].to_s
            raise Kaitoio::Error.new('No node chosen') if node.empty?
            run = Kaitoio::Agent::Session.run_chosen(node)
            handle_turn(run, node)
            { 'kind' => 'reply', 'reply' => nil, 'generate' => { 'query' => node },
              'run' => run.merge('selectedNode' => { 'nodeType' => node, 'from' => 'user' }) }
          end
        end

        dialog.add_action_callback('agent_allow_cost') do |_ctx|
          guard('agent_allow_cost') do
            Kaitoio::Agent::Session.allow_cost!
            { 'allowed' => true }
          end
        end

        dialog.add_action_callback('agent_open_file') do |_ctx, json|
          guard('agent_open_file') do
            { 'opened' => Kaitoio::Render.open_file(parse_args(json)['path']) }
          end
        end

        dialog.add_action_callback('agent_reset') do |_ctx|
          guard('agent_reset') do
            stop_polling
            Kaitoio::Agent::Session.reset!
            { 'reset' => true }
          end
        end
      end

      # ---- oauth pump ------------------------------------------------

      AUTH_TIMEOUT = 180

      # Status vocabulary is not guaranteed, so match generously and never
      # poll indefinitely.
      TERMINAL = %w[succeeded success completed complete done finished
                    failed error canceled cancelled timeout].freeze
      FAILED   = %w[failed error canceled cancelled timeout].freeze
      MAX_RUN_SECONDS = 600

      def start_auth_pump
        stop_auth_pump
        @auth_deadline = Time.now + AUTH_TIMEOUT
        @auth_timer = UI.start_timer(0.5, true) { auth_tick }
        nil
      end

      def stop_auth_pump
        UI.stop_timer(@auth_timer) if @auth_timer
        @auth_timer = nil
      end

      def auth_tick
        state = Kaitoio::Mcp::OAuth.pump
        if state == :done
          stop_auth_pump
          push('agent_signin_done', 'ok' => true, 'data' => { 'signedIn' => true })
        elsif Time.now > @auth_deadline
          stop_auth_pump
          Kaitoio::Mcp::OAuth.stop_listener
          push('agent_signin_done', 'ok' => false, 'error' => 'Sign-in timed out after 3 minutes.')
        end
      rescue => e
        stop_auth_pump
        Kaitoio::Mcp::OAuth.stop_listener
        Kaitoio.log_error('MCP sign-in failed', e)
        push('agent_signin_done', 'ok' => false, 'error' => "#{e.class}: #{e.message}")
      end

      # ---- run lifecycle --------------------------------------------

      def handle_turn(res, prompt)
        case res['kind']
        when 'pending' then start_polling(res['executionId'], prompt)
        when 'result'  then deliver(res['executionId'], prompt, res)
        end
      end

      def deliver(execution_id, prompt, run = nil)
        unless execution_id
          # No execution id means the run never started -- surface why rather
          # than the old placeholder, which left the panel stuck on
          # "generating…" with nothing to act on. The server's reply can be
          # kilobytes of candidate JSON, so reduce it to its message.
          return push('agent_output', 'ok' => false,
                      'error' => "The run did not start. #{failure_reason(run)}".strip)
        end
        out = Kaitoio::Agent::Session.collect_output(execution_id, prompt)

        if out['kind'] == 'pending'
          # Outputs are not ready yet; resume polling rather than ending the
          # turn with an envelope the user cannot act on.
          Kaitoio.log('outputs not ready yet; still polling')
          return start_polling(execution_id, prompt)
        end

        out['dataUri'] = preview_uri(out['entry']) if out['entry']
        push('agent_output', 'ok' => true, 'data' => out)
      end

      # Pull the human-readable message out of an MCP failure payload.
      def failure_reason(run)
        raw = run && (run['text'] || run['status']).to_s
        return '' if raw.empty?
        begin
          json = raw[/\{.*\}/m]
          if json
            obj = JSON.parse(json)
            if obj.is_a?(Hash)
              msg  = obj['message'] || obj['error']
              code = obj['code']
              return [code, msg].compact.join(': ') unless msg.to_s.empty? && code.to_s.empty?
            end
          end
        rescue JSON::ParserError
          nil
        end
        raw.length > 300 ? "#{raw[0, 300]}…" : raw
      end

      def start_polling(execution_id, prompt)
        stop_polling
        @exec_id        = execution_id
        @prompt         = prompt
        @run_started    = Time.now
        @seen_events    = {}
        @last_percent   = 0
        @saw_completion = false
        @last_logged_message = nil
        interval = (Kaitoio::Settings.load['poll_interval_seconds'] || 2).to_i
        interval = 2 if interval <= 0
        @timer = UI.start_timer(interval, true) { tick }
        nil
      end

      # Everything the panel needs to show real progress rather than a
      # spinner: percent, the newest event line, the node, and elapsed time.
      def normalize_status(body)
        (body['status'] || body['state'] || body['executionStatus']).to_s.strip.downcase
      end

      def outputs?(body)
        out = body['outputs'] || body['output']
        out.is_a?(Hash) ? !out.empty? : !out.to_s.empty?
      end

      COMPLETION_EVENTS = %w[node.completed execution.completed run.completed
                             mcp.execution.completed execution.succeeded].freeze

      def progress_payload(status, body)
        fresh = []
        # get_graph_run_events returns newest first; walk oldest-first so the
        # log reads forwards and the "latest" line is genuinely the latest.
        Kaitoio::Agent::Session.events(@exec_id).reverse.each do |ev|
          key = ev['id'] || "#{ev['type']}:#{ev['timestamp'] || ev['createdAt']}:#{ev['message']}"
          next if @seen_events.key?(key)
          @seen_events[key] = true
          fresh << ev
        end

        @saw_completion ||= fresh.any? { |e| COMPLETION_EVENTS.include?(e['type'].to_s) }

        latest = fresh.reverse.find { |e| !e['message'].to_s.strip.empty? } || fresh.last
        pct    = fresh.map { |e| e['progress'] }.compact.map { |v| (v.to_f * 100).round }.max
        @last_percent = pct if pct && pct > @last_percent.to_i

        fresh.each { |ev| Kaitoio.log(event_line(@exec_id, ev)) if worth_logging?(ev) }

        { 'status'  => status,
          'percent' => @last_percent.to_i,
          'node'    => body['nodeTitle'] || body['nodeType'],
          'message' => latest && (latest['message'] || latest['type']),
          'elapsed' => (Time.now - (@run_started || Time.now)).round,
          'events'  => fresh.length }
      rescue => e
        Kaitoio.log("progress unavailable: #{e.message}", 'WARN')
        { 'status' => status, 'percent' => @last_percent.to_i,
          'elapsed' => (Time.now - (@run_started || Time.now)).round }
      end

      # The console was drowning in node.progress and repeated IN_PROGRESS.
      # Percentages belong on the panel's bar, not in the log; only lifecycle
      # events and genuinely new messages are worth a line.
      NOISY_TYPES = %w[node.progress].freeze

      def worth_logging?(ev)
        type = ev['type'].to_s
        return false if NOISY_TYPES.include?(type)

        msg = ev['message'].to_s.strip
        return true if msg.empty?                 # lifecycle events keep their line
        return false if msg == @last_logged_message

        @last_logged_message = msg
        true
      end

      def short_id(id)
        id.to_s.sub(/\Amcp_run_/, '')[0, 8]
      end

      def event_line(execution_id, ev)
        pct = ev['progress'].nil? ? '' : " #{(ev['progress'].to_f * 100).round}%"
        msg = ev['message'].to_s
        "[#{short_id(execution_id)}] #{ev['type']}#{pct}#{msg.empty? ? '' : ' ' + msg}"
      end

      def stop_polling
        UI.stop_timer(@timer) if @timer
        @timer   = nil
        @exec_id = nil
      end

      def tick
        return stop_polling unless @exec_id

        res    = Kaitoio::Agent::Session.poll(@exec_id)
        body   = res['structured'] || {}
        status = normalize_status(body)

        push('agent_status', 'ok' => true, 'data' => progress_payload(status, body))

        # A run that finishes but whose status string we do not recognise used
        # to poll forever and never deliver, so completion is also inferred
        # from the events and from outputs appearing on the record.
        # Only the status endpoint decides terminality. Inferring it from a
        # node.completed event delivered while the execution was still
        # settling, and get_displayable_outputs answered "still running".
        finished = TERMINAL.include?(status)
        timed_out = (Time.now - (@run_started || Time.now)) > MAX_RUN_SECONDS

        unless finished || timed_out
          return
        end

        id = @exec_id
        prompt = @prompt
        stop_polling

        if timed_out && !finished
          return push('agent_output', 'ok' => false,
                      'error' => "Gave up after #{MAX_RUN_SECONDS / 60} minutes (last status: #{status})")
        end

        if FAILED.include?(status)
          push('agent_output', 'ok' => false, 'error' => "Run #{status}: #{failure_reason(res)}")
        else
          deliver(id, prompt)
        end
      rescue => e
        Kaitoio.log_error('agent poll failed', e)
        stop_polling
        push('agent_output', 'ok' => false, 'error' => "#{e.class}: #{e.message}")
      end

      # ---- helpers ---------------------------------------------------

      def parse_args(json)
        parsed = JSON.parse(json.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def nilify(v)
        s = v.to_s
        s.strip.empty? ? nil : s
      end

      def preview_uri(entry)
        return nil unless entry && Kaitoio::Render.image?(entry['contentType'])
        data_uri(entry['path'], entry['contentType'])
      end

      def data_uri(path, content_type)
        return nil unless path && File.file?(path)
        "data:#{content_type};base64,#{Base64.strict_encode64(File.binread(path))}"
      rescue => e
        Kaitoio.log_error("agent data uri failed for #{path}", e)
        nil
      end
    end
  end
end
