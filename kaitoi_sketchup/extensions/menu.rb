require_relative '../ui/dialog'
require_relative '../ui/agent_dialog'
require_relative '../ui/credentials_dialog'

module Kaitoio
  module Extensions
    module Menu
      def self.dev_mode?
        Kaitoio::Settings.load['dev_mode'] == true
      rescue
        false
      end

      def self.install
        menu = UI.menu('Plugins').add_submenu('Kaitoio')

        menu.add_item('Open Panel...')  { Kaitoio::Dialogs::Dialog.show }
        menu.add_item('Kaitoi Agent...') { Kaitoio::Dialogs::AgentDialog.show }
        menu.add_separator
        menu.add_item('Credentials...')  { Kaitoio::Dialogs::CredentialsDialog.show('api') }
        menu.add_item('Set MCP Token...') { Kaitoio::Dialogs::CredentialsDialog.show('mcp') }
        # Developer tools are hidden by default. Enable with
        #   Kaitoio::Settings.update('dev_mode' => true)
        # and reopen SketchUp, or just call Kaitoio.reload! / Kaitoio.self_test!
        # from the Ruby Console, which work regardless.
        return unless dev_mode?

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
