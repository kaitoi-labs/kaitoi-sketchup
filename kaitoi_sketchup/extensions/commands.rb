require_relative '../settings'
require_relative '../render'
require_relative '../ui/credentials_dialog'

module Kaitoio
  module Extensions
    # Menu command implementations. The panel is the real UI; these exist so
    # the API key can be set before the panel is ever opened.
    module Commands
      module_function

      # Opens the credentials editor, which carries both the REST key and the
      # MCP token. UI.inputbox could not show a full token or endpoint -- its
      # fields are fixed-width and its labels truncate.
      def set_api_key
        Kaitoio::Dialogs::CredentialsDialog.show('api')
      end

      def test_connection
        unless Kaitoio::Settings.configured?
          UI.messagebox('Set your API key first (Plugins > Kaitoio > Set API Key...).')
          return false
        end
        Kaitoio::Render.node_types.list(limit: 1)
        UI.messagebox("Connected to #{Kaitoio::Settings.api_base}")
        true
      rescue Kaitoio::Error => e
        UI.messagebox("Connection failed:\n#{e}")
        false
      end

      def open_downloads
        UI.openURL("file://#{Kaitoio::Settings.download_dir}")
      end

      def open_log
        UI.openURL("file://#{Kaitoio.log_path}")
      end
    end
  end
end
