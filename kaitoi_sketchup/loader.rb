require 'sketchup'
require 'time'

require_relative 'version'
require_relative 'settings'
require_relative 'history'
require_relative 'api/errors'
require_relative 'api/client'
require_relative 'api/files'
require_relative 'api/projects'
require_relative 'api/runs'
require_relative 'api/node_types'
require_relative 'api/templates'
require_relative 'model/exporters'
require_relative 'render'
require_relative 'graph/builder'
require_relative 'extensions/commands'
require_relative 'extensions/menu'
require_relative 'mcp/client'
require_relative 'agent/session'
require_relative 'agent/api'
require_relative 'agent/self_test'
require_relative 'ui/dialog'
require_relative 'ui/agent_dialog'
require_relative 'ui/credentials_dialog'

module Kaitoio
  def self.install
    Extensions::Menu.install
    File.write(log_path, '') rescue nil
    log "Kaitoio plugin v#{VERSION} installed"
  end

  # Single logging entry point. Writes to the Ruby Console (so the user
  # sees everything live) AND appends to the plugin log file.
  def self.log(msg, level = 'INFO')
    line = "[#{Time.now.utc.iso8601}] [#{level}] [Kaitoio] #{msg}"
    puts line
    begin
      require 'fileutils'
      FileUtils.mkdir_p(File.dirname(log_path))
      File.open(log_path, 'a') { |f| f.puts(line) }
    rescue => e
      puts "[Kaitoio] log file error: #{e.message}"
    end
  end

  def self.log_error(msg, err = nil)
    detail = msg.to_s
    if err
      detail += " :: #{err.class}: #{err.message}"
      detail += "\n  " + (err.backtrace || []).first(8).join("\n  ")
    end
    log(detail, 'ERROR')
  end

  def self.log_path
    File.join(ENV['HOME'], '.kaitoi_sketchup', 'plugin.log')
  end

  # Dev helper: re-`load` every plugin file (bypasses the require cache) so
  # edits take effect without restarting SketchUp. Reopen the panel after.
  RELOAD_FILES = %w[
    version settings history
    api/errors api/client api/files api/projects api/runs api/node_types
    api/templates model/exporters render graph/builder extensions/commands
    mcp/client agent/session agent/api agent/self_test
    ui/dialog ui/agent_dialog ui/credentials_dialog
  ].freeze

  def self.reload!
    base = File.dirname(__FILE__)
    # Re-loading a file redefines its constants, and Ruby warns about each
    # one. That is expected here and buried the real output, so warnings are
    # suppressed for the duration of the reload only.
    previous = $VERBOSE
    $VERBOSE = nil
    RELOAD_FILES.each { |f| load File.join(base, "#{f}.rb") }
    $VERBOSE = previous
    log "Reloaded #{RELOAD_FILES.length} files (v#{VERSION})"
    true
  rescue => e
    $VERBOSE = previous if defined?(previous)
    log_error('reload failed', e)
    false
  end
end

unless file_loaded?(__FILE__)
  Kaitoio.install
  file_loaded(__FILE__)
end
