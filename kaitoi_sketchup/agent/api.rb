require_relative 'session'

module Kaitoio
  # Scripting facade for the Ruby Console.
  #
  # SketchUp's built-in AI Assistant is a closed, signed extension: its Ruby
  # ships as encrypted .rbe, its agent list is fixed in config.json, and it
  # exposes no hook for third-party tools or providers. There is therefore no
  # supported way to register the Kaitoi MCP server with it.
  #
  # What *is* supported: its RUBY_AGENT writes and runs Ruby. These one-call
  # methods give it (and you, in the Ruby Console) a stable surface to drive
  # the Kaitoi MCP bridge:
  #
  #   Kaitoio.ask("make this photoreal, golden hour")
  #   Kaitoio.capture
  #   Kaitoio.mcp_status
  #
  # These block until the run finishes, unlike the Agent panel which polls on
  # a timer. That is deliberate: a console script cannot receive a callback.
  # SketchUp is unresponsive while they run.
  module ScriptingApi
    DEFAULT_TIMEOUT = 300

    # Capture the viewport, send `text` to the MCP server, wait, and return
    # the downloaded file path. Raises Kaitoio::Error on failure.
    def ask(text, capture: true, timeout: DEFAULT_TIMEOUT, poll: 2)
      session = Kaitoio::Agent::Session
      session.mcp.ensure_initialized!

      if capture && session.attached.nil?
        shot = Kaitoio::Render.capture_view
        session.attach_capture(shot['path'])
      end

      res = session.ask(text, use_capture: capture)

      if res['kind'] == 'cost'
        log("run needs cost confirmation; re-run with Kaitoio.confirm(#{text.inspect})", 'WARN')
        return res
      end

      execution_id = res['executionId']
      if res['kind'] == 'pending' && execution_id
        deadline = Time.now + timeout
        loop do
          raise Kaitoio::Error.new("Run did not finish within #{timeout}s") if Time.now > deadline
          sleep(poll)
          body   = session.poll(execution_id)['structured'] || {}
          status = body['status'].to_s
          log("run #{execution_id}: #{status}")
          break if %w[succeeded completed failed canceled].include?(status)
          raise Kaitoio::Error.new("Run #{status}") if %w[failed canceled].include?(status)
        end
      end

      return res unless execution_id

      out = session.collect_output(execution_id, text)
      out['entry'] ? out['entry']['path'] : out['text']
    end

    # Same as ask, but confirms a costly run.
    def confirm(text, timeout: DEFAULT_TIMEOUT)
      session = Kaitoio::Agent::Session
      res = session.ask(text, use_capture: true, confirm_cost: true)
      id  = res['executionId']
      return res unless id
      ask_wait(id, text, timeout)
    end

    def ask_wait(execution_id, text, timeout)
      session  = Kaitoio::Agent::Session
      deadline = Time.now + timeout
      loop do
        raise Kaitoio::Error.new("Run did not finish within #{timeout}s") if Time.now > deadline
        body   = session.poll(execution_id)['structured'] || {}
        status = body['status'].to_s
        break if %w[succeeded completed].include?(status)
        raise Kaitoio::Error.new("Run #{status}") if %w[failed canceled].include?(status)
        sleep(2)
      end
      out = session.collect_output(execution_id, text)
      out['entry'] ? out['entry']['path'] : out['text']
    end

    # Capture the viewport and attach it for the next ask. Returns the path.
    def capture
      shot = Kaitoio::Render.capture_view
      Kaitoio::Agent::Session.attach_capture(shot['path'])
      shot['path']
    end

    def mcp_status
      Kaitoio::Agent::Session.status
    end

    def mcp_tools
      Kaitoio::Agent::Session.tool_names
    end

    def agent_panel
      Kaitoio::Dialogs::AgentDialog.show
    end

    # Non-blocking end-to-end check: viewport -> image -> video.
    def self_test!
      Kaitoio::Dialogs::AgentDialog.show
      Kaitoio::Agent::SelfTest.run!
    end

    def help
      puts <<~TEXT
        Kaitoio #{Kaitoio::VERSION} — Ruby Console API

          Kaitoio.capture                 capture the viewport, attach it
          Kaitoio.ask("a prompt")         capture + run through MCP, returns a file path
          Kaitoio.confirm("a prompt")     same, confirming a costly run
          Kaitoio.mcp_status              server info and tool count
          Kaitoio.mcp_tools               available MCP tool names
          Kaitoio.agent_panel             open the Agent panel
          Kaitoio.self_test!              viewport -> image -> video, end to end
          Kaitoio.reload!                 reload plugin Ruby after editing

        These block SketchUp until the run finishes. Use the Agent panel for
        long runs — it polls on a timer and stays responsive.
      TEXT
      true
    end
  end

  extend ScriptingApi
end
