require 'sketchup'
require 'time'

require_relative 'kaitoi_sketchup/version'
require_relative 'kaitoi_sketchup/settings'
require_relative 'kaitoi_sketchup/history'
require_relative 'kaitoi_sketchup/api/errors'
require_relative 'kaitoi_sketchup/api/client'
require_relative 'kaitoi_sketchup/api/files'
require_relative 'kaitoi_sketchup/api/projects'
require_relative 'kaitoi_sketchup/api/runs'
require_relative 'kaitoi_sketchup/api/node_types'
require_relative 'kaitoi_sketchup/api/templates'
require_relative 'kaitoi_sketchup/model/exporters'
require_relative 'kaitoi_sketchup/render'
require_relative 'kaitoi_sketchup/graph/builder'
require_relative 'kaitoi_sketchup/extensions/commands'
require_relative 'kaitoi_sketchup/extensions/menu'
require_relative 'kaitoi_sketchup/ui/dialog'

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
    kaitoi_sketchup/version kaitoi_sketchup/settings kaitoi_sketchup/history
    kaitoi_sketchup/api/errors kaitoi_sketchup/api/client kaitoi_sketchup/api/files
    kaitoi_sketchup/api/projects kaitoi_sketchup/api/runs kaitoi_sketchup/api/node_types
    kaitoi_sketchup/api/templates kaitoi_sketchup/model/exporters kaitoi_sketchup/render
    kaitoi_sketchup/graph/builder kaitoi_sketchup/extensions/commands kaitoi_sketchup/ui/dialog
  ].freeze

  def self.reload!
    base = File.dirname(__FILE__)
    RELOAD_FILES.each { |f| load File.join(base, "#{f}.rb") }
    log "Reloaded #{RELOAD_FILES.length} files (v#{VERSION})"
    true
  rescue => e
    log_error('reload failed', e)
    false
  end
end

unless file_loaded?(__FILE__)
  Kaitoio.install
  file_loaded(__FILE__)
end
