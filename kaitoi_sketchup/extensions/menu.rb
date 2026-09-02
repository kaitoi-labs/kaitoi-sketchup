require_relative '../ui/dialog'
require_relative '../ui/agent_dialog'

module Kaitoio
  module Extensions
    module Menu
      def self.install
        menu = UI.menu('Plugins').add_submenu('Kaitoio')

        menu.add_item('Open Panel...')  { Kaitoio::Dialogs::Dialog.show }
        menu.add_item('Kaitoi Agent...') { Kaitoio::Dialogs::AgentDialog.show }
        menu.add_separator
        menu.add_item('Set API Key...') { Commands.set_api_key }
        menu.add_separator
        menu.add_item('Reload (dev)') do
          Kaitoio.reload!
          Kaitoio::Dialogs::Dialog.close rescue nil
          Kaitoio::Dialogs::AgentDialog.close rescue nil
        end
      end
    end
  end
end
