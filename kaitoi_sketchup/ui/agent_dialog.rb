require 'json'
require 'base64'

require_relative '../settings'
require_relative '../history'
require_relative '../render'
require_relative '../agent/session'

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
        @dialog.set_on_closed { stop_polling; @dialog = nil }
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
            cfg = Kaitoio::Settings.load
            { 'version'  => Kaitoio::VERSION,
              'mcpUrl'   => cfg['mcp_url'],
              'hasKey'   => !(cfg['mcp_api_key'].to_s.empty? && cfg['api_key'].to_s.empty?),
              'attached' => Kaitoio::Agent::Session.attached,
              'history'  => Kaitoio::History.list.select { |h| h['kind'] == 'agent' } }
          end
        end

        dialog.add_action_callback('agent_connect') do |_ctx|
          guard('agent_connect') { Kaitoio::Agent::Session.status }
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

        dialog.add_action_callback('agent_send') do |_ctx, json|
          guard('agent_send') do
            args = parse_args(json)
            res  = Kaitoio::Agent::Session.ask(
              args['text'],
              use_capture:  args['useCapture'] != false,
              confirm_cost: args['confirmCost'] == true,
              idempotency_key: nilify(args['idempotencyKey'])
            )
            handle_turn(res, args['text'])
            res
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

      # ---- run lifecycle --------------------------------------------

      def handle_turn(res, prompt)
        case res['kind']
        when 'pending' then start_polling(res['executionId'], prompt)
        when 'result'  then deliver(res['executionId'], prompt)
        end
      end

      def deliver(execution_id, prompt)
        return push('agent_output', 'ok' => true, 'data' => { 'kind' => 'text', 'text' => '(no execution id)' }) unless execution_id
        out = Kaitoio::Agent::Session.collect_output(execution_id, prompt)
        out['dataUri'] = preview_uri(out['entry']) if out['entry']
        push('agent_output', 'ok' => true, 'data' => out)
      end

      def start_polling(execution_id, prompt)
        stop_polling
        @exec_id = execution_id
        @prompt  = prompt
        interval = (Kaitoio::Settings.load['poll_interval_seconds'] || 2).to_i
        interval = 2 if interval <= 0
        @timer = UI.start_timer(interval, true) { tick }
        nil
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
        status = (body['status'] || '').to_s
        push('agent_status', 'ok' => true, 'data' => { 'status' => status, 'text' => res['text'] })
        return unless %w[succeeded failed canceled completed].include?(status)

        id = @exec_id
        prompt = @prompt
        stop_polling
        if %w[succeeded completed].include?(status)
          deliver(id, prompt)
        else
          push('agent_output', 'ok' => false, 'error' => "Run #{status}: #{res['text']}")
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
