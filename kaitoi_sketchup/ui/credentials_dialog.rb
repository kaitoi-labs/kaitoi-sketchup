require 'json'

require_relative '../settings'

module Kaitoio
  module Dialogs
    # Credentials editor.
    #
    # UI.inputbox is a fixed-width native dialog: long tokens and URLs are
    # clipped and its labels are truncated, so a key could not be read back
    # to check it. This is an HtmlDialog with full-width fields, a reveal
    # toggle, and a live Test for each API.
    module CredentialsDialog
      module_function

      HTML_DIR = File.join(File.dirname(__FILE__), 'html')

      def show(focus = 'api')
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          @dialog.execute_script("window.kaitoi && window.kaitoi.focusSection(#{JSON.generate(focus.to_s)});")
          return @dialog
        end

        @focus  = focus.to_s
        @dialog = UI::HtmlDialog.new(
          dialog_title:    'Kaitoio — Credentials',
          preferences_key: 'io.kaitoi.sketchup.credentials',
          scrollable:      true,
          resizable:       true,
          width:           720,
          height:          560,
          min_width:       560,
          min_height:      420,
          style:           UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_file(File.join(HTML_DIR, 'credentials.html'))
        attach_callbacks(@dialog)
        @dialog.set_on_closed { @dialog = nil }
        @dialog.show
        @dialog
      end

      def close
        @dialog.close if @dialog
        @dialog = nil
      end

      def guard(channel)
        push(channel, 'ok' => true, 'data' => yield)
      rescue Kaitoio::Error => e
        push(channel, 'ok' => false, 'error' => e.to_s)
      rescue => e
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
        dialog.add_action_callback('creds_boot') do |_ctx|
          guard('creds_boot') do
            cfg = Kaitoio::Settings.load
            { 'focus'       => @focus,
              'apiKeySet'   => !cfg['api_key'].to_s.empty?,
              'apiKeyHint'  => hint(cfg['api_key']),
              'baseUrl'     => cfg['base_url'],
              'apiPath'     => cfg['api_path'],
              'mcpTokenSet' => !cfg['mcp_token'].to_s.empty?,
              'mcpTokenHint'=> hint(cfg['mcp_token']),
              'mcpUrl'      => cfg['mcp_url'],
              'oauthSignedIn' => defined?(Kaitoio::Mcp::OAuth) ? Kaitoio::Mcp::OAuth.signed_in? : false,
              'configPath'  => Kaitoio::Settings.path }
          end
        end

        dialog.add_action_callback('creds_save') do |_ctx, json|
          guard('creds_save') do
            a = parse_args(json)
            updates = {}
            # A blank secret means "keep the stored one" -- never clobber a
            # working key just because the field was left empty.
            updates['api_key']   = a['apiKey'].to_s   unless a['apiKey'].to_s.strip.empty?
            updates['mcp_token'] = a['mcpToken'].to_s unless a['mcpToken'].to_s.strip.empty?
            updates['base_url']  = a['baseUrl'].to_s  unless a['baseUrl'].to_s.strip.empty?
            updates['api_path']  = a['apiPath'].to_s  unless a['apiPath'].to_s.strip.empty?
            updates['mcp_url']   = a['mcpUrl'].to_s   unless a['mcpUrl'].to_s.strip.empty?
            Kaitoio::Settings.update(updates) unless updates.empty?

            cfg = Kaitoio::Settings.load
            { 'saved'        => updates.keys,
              'apiBase'      => Kaitoio::Settings.api_base,
              'apiKeySet'    => !cfg['api_key'].to_s.empty?,
              'apiKeyHint'   => hint(cfg['api_key']),
              'mcpTokenSet'  => !cfg['mcp_token'].to_s.empty?,
              'mcpTokenHint' => hint(cfg['mcp_token']) }
          end
        end

        dialog.add_action_callback('creds_test_api') do |_ctx|
          guard('creds_test_api') do
            Kaitoio::Render.node_types.list(limit: 1)
            { 'base' => Kaitoio::Settings.api_base }
          end
        end

        dialog.add_action_callback('creds_test_mcp') do |_ctx|
          guard('creds_test_mcp') do
            c = Kaitoio::Mcp::Client.new
            c.ensure_initialized!
            { 'url' => c.url, 'mode' => c.auth_mode,
              'server' => c.server_info, 'tools' => c.tools.length }
          end
        end

        dialog.add_action_callback('creds_open_config') do |_ctx|
          guard('creds_open_config') do
            UI.openURL("file://#{File.dirname(Kaitoio::Settings.path)}")
            { 'opened' => true }
          end
        end
      end

      # Enough characters to recognise a key without printing it.
      def hint(value)
        s = value.to_s
        return '' if s.empty?
        return "#{'•' * s.length}" if s.length < 12
        "#{s[0, 10]}…#{s[-6, 6]}  (#{s.length} chars)"
      end

      def parse_args(json)
        parsed = JSON.parse(json.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
