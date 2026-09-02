require_relative '../ui/dialog'
require_relative '../ui/agent_dialog'
require_relative '../ui/credentials_dialog'

module Kaitoio
  module Extensions
    module Menu
      def self.install
        menu = UI.menu('Plugins').add_submenu('Kaitoio')

        menu.add_item('Open Panel...')  { Kaitoio::Dialogs::Dialog.show }
        menu.add_item('Kaitoi Agent...') { Kaitoio::Dialogs::AgentDialog.show }
        menu.add_separator
        menu.add_item('Credentials...')  { Kaitoio::Dialogs::CredentialsDialog.show('api') }
        menu.add_item('Set MCP Token...') { Kaitoio::Dialogs::CredentialsDialog.show('mcp') }
        menu.add_separator
        menu.add_item('Run self-test (image -> video)') do
          Kaitoio::Dialogs::AgentDialog.show
          Kaitoio::Agent::SelfTest.run!
        end
        menu.add_item('Reload (dev)') do
          Kaitoio.reload!
          Kaitoio::Dialogs::Dialog.close rescue nil
          Kaitoio::Dialogs::AgentDialog.close rescue nil
          Kaitoio::Dialogs::CredentialsDialog.close rescue nil
        end
      end
    end
  end
end
