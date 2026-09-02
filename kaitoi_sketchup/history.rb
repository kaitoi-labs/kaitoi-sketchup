require 'json'
require 'fileutils'

module Kaitoio
  # Small persisted log of recent generations (render + project runs), each
  # pointing at the downloaded output file. Stored in the plugin app-data dir.
  module History
    MAX = 50

    def self.path
      dir = File.join(ENV['HOME'], '.kaitoi_sketchup')
      FileUtils.mkdir_p(dir)
      File.join(dir, 'history.json')
    end

    def self.list
      return [] unless File.exist?(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Array) ? data : []
    rescue JSON::ParserError
      []
    end

    def self.add(entry)
      items = list
      items.unshift(entry)
      items = items.first(MAX)
      write_atomic(JSON.pretty_generate(items))
      items
    rescue => e
      Kaitoio.log_error('history add failed', e) if defined?(Kaitoio) && Kaitoio.respond_to?(:log_error)
      list
    end

    def self.clear
      write_atomic('[]')
      []
    rescue
      []
    end

    # Write to a temp file in the same directory, then rename. A crash mid-write
    # can no longer leave a truncated history.json behind.
    def self.write_atomic(content)
      tmp = "#{path}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(content) }
      File.rename(tmp, path)
    end
  end
end
