require 'json'
require 'time'

require_relative '../settings'
require_relative '../history'
require_relative '../render'

module Kaitoio
  module Dialogs
    # UI::HtmlDialog wrapper.
    #
    # The JS side never speaks HTTP. It calls action callbacks here; Ruby
    # calls the API and pushes results back with execute_script. That keeps
    # the Bearer token inside Ruby and sidesteps CORS entirely.
    #
    # Long runs are polled with UI.start_timer (main thread, repeating)
    # because SketchUp does not reliably schedule background Ruby threads.
    module Dialog
      module_function

      HTML_DIR = File.join(File.dirname(__FILE__), 'html')

      # Panel selections remembered as the user edits, so they survive closing
      # the panel or restarting SketchUp -- not only a completed run.
      REMEMBERED = %w[last_node_type last_prompt last_template_id last_template_prompt].freeze

      def instance
        @dialog
      end

      def show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return @dialog
        end

        @dialog = UI::HtmlDialog.new(
          dialog_title:    "Kaitoio #{Kaitoio::VERSION}",
          preferences_key: 'io.kaitoi.sketchup.panel',
          scrollable:      true,
          resizable:       true,
          width:           980,
          height:          760,
          min_width:       620,
          min_height:      480,
          style:           UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_file(File.join(HTML_DIR, 'index.html'))
        attach_callbacks(@dialog)
        @dialog.set_on_closed { stop_polling; @dialog = nil }
        @dialog.show
        @dialog
      end

      def close
        stop_polling
        @dialog.close if @dialog
        @dialog = nil
      end

      # ---- JS bridge ------------------------------------------------------

      # Every callback funnels through here so one rescue turns any API error
      # into a panel-visible message instead of a silent Ruby Console trace.
      def guard(channel)
        payload = yield
        push(channel, 'ok' => true, 'data' => payload)
      rescue Kaitoio::Error => e
        Kaitoio.log_error("#{channel} failed", e)
        push(channel, 'ok' => false, 'error' => e.to_s, 'code' => e.code)
      rescue => e
        Kaitoio.log_error("#{channel} failed", e)
        push(channel, 'ok' => false, 'error' => "#{e.class}: #{e.message}")
      end

      def push(channel, payload)
        return unless @dialog
        js = "window.kaitoi && window.kaitoi.receive(#{JSON.generate(channel)}, #{JSON.generate(payload)});"
        @dialog.execute_script(js)
        nil
      end

      def attach_callbacks(dialog)
        dialog.add_action_callback('boot') do |_ctx|
          guard('boot') do
            cfg = Kaitoio::Settings.load
            { 'version'    => Kaitoio::VERSION,
              'configured' => Kaitoio::Settings.configured?,
              'settings'   => redact(cfg),
              'webUrl'     => Kaitoio::Settings.web_url,
              'downloadDir'=> Kaitoio::Settings.download_dir,
              'history'    => Kaitoio::History.list }
          end
        end

        dialog.add_action_callback('save_settings') do |_ctx, json|
          guard('save_settings') do
            incoming = JSON.parse(json.to_s)
            # A blank api_key means "leave the stored one alone".
            incoming.delete('api_key')     if incoming['api_key'].to_s.strip.empty?
            incoming.delete('mcp_api_key') if incoming['mcp_api_key'].to_s.strip.empty?
            redact(Kaitoio::Settings.update(incoming))
          end
        end

        dialog.add_action_callback('remember') do |_ctx, json|
          begin
            incoming = JSON.parse(json.to_s)
            values   = incoming.select { |k, _| REMEMBERED.include?(k) }
            Kaitoio::Settings.update(values) unless values.empty?
          rescue => e
            Kaitoio.log_error('remember failed', e)
          end
          nil   # fire-and-forget: no push, this fires on every keystroke pause
        end

        dialog.add_action_callback('test_connection') do |_ctx|
          guard('test_connection') do
            Kaitoio::Render.node_types.list(limit: 1)
            { 'base' => Kaitoio::Settings.api_base }
          end
        end

        dialog.add_action_callback('check_credits') do |_ctx|
          guard('check_credits') { Kaitoio::Render.client.account_credits }
        end

        dialog.add_action_callback('list_node_types') do |_ctx, json|
          guard('list_node_types') do
            args = parse_args(json)
            Kaitoio::Render.node_types.list(
              limit:  (args['limit'] || 50).to_i,
              cursor: args['cursor'],
              search: nilify(args['search'])
            )
          end
        end

        dialog.add_action_callback('capture') do |_ctx|
          guard('capture') do
            shot = Kaitoio::Render.capture_view
            shot.merge('dataUri' => data_uri(shot['path'], 'image/png'))
          end
        end

        dialog.add_action_callback('generate') do |_ctx, json|
          guard('generate') do
            args = parse_args(json)
            run = Kaitoio::Render.start_node_run(
              node_type:  args['nodeType'],
              prompt:     args['prompt'],
              image_path: nilify(args['imagePath'])
            )
            start_polling(run, kind: 'render', label: args['nodeType'], prompt: args['prompt'])
            run
          end
        end

        dialog.add_action_callback('list_templates') do |_ctx, json|
          guard('list_templates') do
            args = parse_args(json)
            Kaitoio::Render.templates.list(limit: 100, search: nilify(args['search']))
          end
        end

        dialog.add_action_callback('run_template') do |_ctx, json|
          guard('run_template') do
            args = parse_args(json)
            run = Kaitoio::Render.start_template_run(
              template_id: args['templateId'],
              endpoint_id: nilify(args['endpointId']),
              prompt:      args['prompt'],
              image_path:  nilify(args['imagePath'])
            )
            start_polling(run, kind: 'template', label: args['templateName'],
                               prompt: args['prompt'],
                               template: [args['templateId'], args['endpointId']])
            run
          end
        end

        dialog.add_action_callback('cancel_run') do |_ctx, json|
          guard('cancel_run') do
            args = parse_args(json)
            id = nilify(args['runId']) || @poll_run_id
            raise Kaitoio::Error.new('No run in flight') unless id
            Kaitoio::Render.runs.cancel(id)
          end
        end

        dialog.add_action_callback('list_history') do |_ctx|
          guard('list_history') { Kaitoio::History.list }
        end

        dialog.add_action_callback('clear_history') do |_ctx|
          guard('clear_history') { Kaitoio::History.clear }
        end

        dialog.add_action_callback('open_file') do |_ctx, json|
          guard('open_file') do
            args = parse_args(json)
            { 'opened' => Kaitoio::Render.open_file(args['path']) }
          end
        end

        dialog.add_action_callback('open_log') do |_ctx|
          guard('open_log') { { 'opened' => Kaitoio::Render.open_file(Kaitoio.log_path) } }
        end
      end

      # ---- run polling ----------------------------------------------------

      # UI.start_timer keeps the panel responsive; a worker thread would not
      # be scheduled reliably by SketchUp.
      def start_polling(run, kind:, label: nil, prompt: nil, template: nil)
        stop_polling
        @poll_run_id   = run['id']
        @poll_kind     = kind
        @poll_label    = label
        @poll_prompt   = prompt
        @poll_template = template
        @poll_cursor   = nil
        @poll_seen     = {}
        @poll_started  = Time.now

        interval = (Kaitoio::Settings.load['poll_interval_seconds'] || 2).to_i
        interval = 2 if interval <= 0
        @timer = UI.start_timer(interval, true) { tick }
        nil
      end

      def stop_polling
        UI.stop_timer(@timer) if @timer
        @timer = nil
        @poll_run_id = nil
      end

      def tick
        return stop_polling unless @poll_run_id

        run = fetch_run(@poll_run_id)
        drain_events(@poll_run_id)
        push('run_status', 'ok' => true, 'data' => run)

        return unless Kaitoio::Render.runs.terminal?(run)

        id = @poll_run_id
        stop_polling

        if Kaitoio::Render.runs.succeeded?(run)
          entry = Kaitoio::Render.download_output(run, label: @poll_label,
                                                  prompt: @poll_prompt, kind: @poll_kind)
          push('run_done', 'ok' => true, 'data' => {
            'run' => run, 'entry' => entry,
            'dataUri' => entry && preview_uri(entry),
            'history' => Kaitoio::History.list
          })
        else
          push('run_done', 'ok' => false,
               'error' => run_error_text(run) || "Run #{id} #{run['status']}",
               'data' => { 'run' => run })
        end
      rescue => e
        Kaitoio.log_error('run poll failed', e)
        stop_polling
        push('run_done', 'ok' => false, 'error' => "#{e.class}: #{e.message}")
      end

      def fetch_run(run_id)
        if @poll_template
          tid, eid = @poll_template
          Kaitoio::Render.templates.get_run(tid, eid, run_id)
        else
          Kaitoio::Render.runs.get(run_id)
        end
      end

      # Lifecycle/progress events, drained to the panel AND the Ruby Console.
      #
      # Two API details this has to defend against:
      #   - once caught up the response carries nextCursor: null, and polling
      #     with a stale cursor replays the last page forever, so events are
      #     deduped by id;
      #   - a tick can fall behind, so pages are drained while hasMore.
      MAX_PAGES_PER_TICK = 10
      SEEN_LIMIT         = 5000

      def drain_events(run_id)
        return if @poll_template # template runs expose events only over SSE

        fresh = []
        pages = 0

        loop do
          res = Kaitoio::Render.runs.events(run_id, cursor: @poll_cursor, limit: 100)
          break unless res.is_a?(Hash)

          page = res['data'] || res['items'] || res['events'] || []
          page.each do |ev|
            id = ev['id'] || "#{ev['type']}:#{ev['createdAt']}"
            next if @poll_seen.key?(id)
            @poll_seen[id] = true
            fresh << ev
          end

          nxt = res['nextCursor']
          @poll_cursor = nxt if nxt
          pages += 1
          break unless res['hasMore'] && nxt && pages < MAX_PAGES_PER_TICK
        end

        # Bound memory on very chatty runs; ids are only needed for recent pages.
        @poll_seen = {} if @poll_seen.length > SEEN_LIMIT

        return if fresh.empty?
        fresh.each { |ev| Kaitoio.log(event_line(run_id, ev)) }
        push('run_events', 'ok' => true, 'data' => fresh)
      rescue Kaitoio::ValidationError => e
        # INVALID_CURSOR: restart the stream; dedupe stops it replaying.
        Kaitoio.log("run events cursor reset: #{e.message}", 'WARN')
        @poll_cursor = nil
      rescue Kaitoio::Error => e
        # Progress is a nicety; never let it kill the run.
        Kaitoio.log("run events unavailable: #{e.message}", 'WARN')
      end

      # One console line per event: "[run_abc123] node.progress 40% Node started."
      def event_line(run_id, ev)
        pct = ev['progress'].nil? ? '' : " #{(ev['progress'].to_f * 100).round}%"
        msg = ev['message'].to_s
        short = run_id.to_s.sub(/\Arun_/, '')[0, 8]
        "[#{short}] #{ev['type']}#{pct}#{msg.empty? ? '' : ' ' + msg}"
      end

      # ---- helpers --------------------------------------------------------

      # A run's `error` is a structured object, not a string; rendering it
      # raw in the panel produced "[object Object]".
      def run_error_text(run)
        err = run['error'] || run['failureReason'] || run['message']
        case err
        when nil    then nil
        when String then err
        when Hash   then [err['code'], err['message'] || err['detail']].compact.join(': ')
        else err.to_s
        end
      end

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

      # Never ship the API key back to the panel.
      def redact(cfg)
        out = cfg.dup
        key = out['api_key'].to_s
        out['api_key'] = ''
        out['api_key_set'] = !key.empty?
        out['api_key_hint'] = key.empty? ? '' : "#{key[0, 6]}…#{key[-4, 4]}"

        mcp = out['mcp_api_key'].to_s
        out['mcp_api_key']      = ''
        out['mcp_api_key_set']  = !mcp.empty?
        out['mcp_api_key_hint'] = mcp.empty? ? '' : "#{mcp[0, 6]}…#{mcp[-4, 4]}"
        out
      end

      def preview_uri(entry)
        return nil unless Kaitoio::Render.image?(entry['contentType'])
        data_uri(entry['path'], entry['contentType'])
      end

      # Inline images as data: URIs — the panel has no file:// read access.
      def data_uri(path, content_type)
        return nil unless path && File.file?(path)
        require 'base64'
        "data:#{content_type};base64,#{Base64.strict_encode64(File.binread(path))}"
      rescue => e
        Kaitoio.log_error("data uri failed for #{path}", e)
        nil
      end
    end
  end
end
