require 'json'
require 'fileutils'

module Kaitoio
  module Settings
    DEFAULTS = {
      'base_url'  => 'https://api.studio.kaitoi.io',
      'web_url'   => 'https://studio.kaitoi.io',
      'api_path'  => '/api/v1',
      'api_key'   => '',
      'request_timeout_seconds' => 120,
      'max_retries'             => 3,
      'poll_interval_seconds'   => 2,
      'download_dir'            => '',
      'capture_max_edge'        => 1024,
      # MCP (Kaitoi Agent) is a separate API from the REST one above: its own
      # endpoint, its own credential, scopes mcp:read / mcp:write. A REST key
      # is NOT accepted there.
      #
      # Preferred: mint a token in Kaitoi Studio > Settings > MCP (Bearer,
      # 365 days by default, revocable, scoped to the minting user) and put it
      # in mcp_token. Leave it blank to sign in with OAuth instead.
      'mcp_url'                 => 'https://mcp.studio.kaitoi.io',
      'mcp_token'             => '',
      # Conversation brain for the Agent panel: a vision chat node run over
      # MCP. It sees the viewport capture, so it can talk about the model.
      'agent_chat_node'         => 'builtin/third_party/google/gemini_multimodal',
      'agent_history_turns'     => 8,
      # Last panel selections, restored on reopen.
      'last_node_type'          => '',
      'last_prompt'             => '',
      'last_template_id'        => '',
      'last_template_prompt'    => ''
    }.freeze

    def self.path
      dir = File.join(ENV['HOME'], '.kaitoi_sketchup')
      FileUtils.mkdir_p(dir)
      File.join(dir, 'config.json')
    end

    def self.load
      if File.exist?(path)
        data = JSON.parse(File.read(path))
        DEFAULTS.merge(data)
      else
        DEFAULTS.dup
      end
    rescue JSON::ParserError
      DEFAULTS.dup
    end

    def self.save(values)
      FileUtils.mkdir_p(File.dirname(path))
      # Create with 0600 up front. Writing first and chmod'ing after left the
      # API key world-readable for the width of that gap.
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(JSON.pretty_generate(values))
      end
      File.chmod(0o600, path)
      values
    end

    def self.update(hash)
      save(load.merge(hash))
    end

    def self.set_api_key(key)
      update('api_key' => key.to_s.strip)
    end

    def self.set_base_url(url)
      update('base_url' => url.to_s.strip)
    end

    # Idempotent: pasting the full API base ("https://host/api/v1") into
    # base_url must not produce "https://host/api/v1/api/v1".
    def self.api_base
      cfg  = load
      base = cfg['base_url'].to_s.chomp('/')
      path = cfg['api_path'].to_s.chomp('/')
      return base if path.empty?
      base.end_with?(path) ? base : base + path
    end

    def self.web_url
      cfg = load
      explicit = cfg['web_url'].to_s
      return explicit.chomp('/') unless explicit.empty?
      cfg['base_url'].to_s.sub(%r{://api\.}, '://').chomp('/')
                             .sub(%r{#{Regexp.escape(cfg['api_path'].to_s.chomp('/'))}$}, '')
    end

    def self.api_key
      load['api_key'].to_s
    end

    def self.capture_max_edge
      v = load['capture_max_edge'].to_i
      v.positive? ? v : 1024
    end

    def self.configured?
      key = api_key
      !key.empty? && !api_base.empty?
    end

    def self.download_dir
      d = load['download_dir'].to_s
      return d unless d.empty?
      fallback = File.join(ENV['HOME'], 'KaitoioDownloads')
      FileUtils.mkdir_p(fallback)
      fallback
    end
  end
end
