require_relative '../settings'
require_relative '../render'

module Kaitoio
  module Extensions
    # Menu command implementations. The panel is the real UI; these exist so
    # the API key can be set before the panel is ever opened.
    module Commands
      module_function

      def set_api_key
        current = Kaitoio::Settings.api_key
        masked  = current.empty? ? '' : "#{current[0, 6]}…#{current[-4, 4]}"
        prompts = ['API key', 'Base URL']
        defaults = [masked, Kaitoio::Settings.load['base_url']]

        result = UI.inputbox(prompts, defaults, 'Kaitoio — API key')
        return false unless result

        key, base = result
        # An untouched masked field means "keep the existing key".
        Kaitoio::Settings.set_api_key(key) unless key.to_s.strip.empty? || key == masked
        Kaitoio::Settings.set_base_url(base) unless base.to_s.strip.empty?

        UI.messagebox("Kaitoio settings saved.\n\n#{Kaitoio::Settings.path}")
        true
      rescue => e
        Kaitoio.log_error('set_api_key failed', e)
        UI.messagebox("Could not save settings:\n#{e.message}")
        false
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
