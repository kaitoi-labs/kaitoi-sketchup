require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

require_relative '../api/errors'
require_relative 'oauth'

module Kaitoio
  module Mcp
    # Panels subscribe here to show which MCP tool is running. Kept as a
    # module hook so the client stays unaware of any UI.
    class << self
      attr_accessor :observer
    end

    def self.notify_tool(name, phase, detail = nil)
      observer.call(name, phase, detail) if observer
    rescue => e
      Kaitoio.log("MCP observer error: #{e.message}", 'WARN')
    end

    # Minimal MCP client speaking JSON-RPC 2.0 over Streamable HTTP.
    #
    # Only what the Agent panel needs: initialize, tools/list, tools/call.
    # No SSE subscription -- SketchUp cannot hold a streaming socket on the
    # main thread, so every call is a plain request/response POST. Servers
    # may still answer with a text/event-stream body, which is parsed here.
    class Client
      PROTOCOL_VERSION = '2025-06-18'.freeze

      attr_reader :url, :session_id, :server_info

      def initialize(url: nil, api_key: nil, timeout: nil)
        cfg      = Kaitoio::Settings.load
        @url     = (url || cfg['mcp_url']).to_s
        # MCP is a separate API from REST, and a REST key is rejected there
        # (invalid_token), so there is deliberately no fallback to it. Either
        # an MCP token minted in Studio > Settings > MCP is configured, or we
        # fall back to the OAuth flow.
        @static_key = (api_key || cfg['mcp_token']).to_s
        @timeout = (timeout || cfg['request_timeout_seconds'] || 120).to_i
        @initialized = false
      end

      def configured?
        !@url.empty? && (!@static_key.empty? || Kaitoio::Mcp::OAuth.signed_in?)
      end

      def auth_mode
        @static_key.empty? ? 'oauth' : 'token'
      end

      def bearer
        return @static_key unless @static_key.empty?
        token = Kaitoio::Mcp::OAuth.access_token
        raise Kaitoio::AuthError.new(
          'No MCP credential. Mint a token in Kaitoi Studio > Settings > MCP and set it ' \
          'in Preferences (MCP token), or use Connect in the Agent panel to sign in.',
          code: 'NOT_SIGNED_IN'
        ) unless token
        token
      end

      # ---- handshake -------------------------------------------------

      def ensure_initialized!
        return true if @initialized

        res = rpc('initialize', {
          'protocolVersion' => PROTOCOL_VERSION,
          'capabilities'    => {},
          'clientInfo'      => { 'name' => 'kaitoi-sketchup-agent', 'version' => Kaitoio::VERSION }
        })
        @server_info  = res['serverInfo']
        @initialized  = true
        # Required by the spec; the server may answer 202 with no body.
        notify('notifications/initialized')
        Kaitoio.log("MCP ready: #{@server_info && @server_info['name']} (session #{@session_id || 'none'})")
        true
      end

      def tools
        ensure_initialized!
        (rpc('tools/list', {})['tools'] || [])
      end

      # Returns { 'text' => joined text, 'structured' => Hash|nil, 'raw' => result }
      def call_tool(name, arguments = {})
        ensure_initialized!
        Kaitoio::Mcp.notify_tool(name, 'start', tool_detail(name, arguments))
        started = Time.now
        result  = rpc('tools/call', { 'name' => name, 'arguments' => arguments })
        Kaitoio::Mcp.notify_tool(name, 'done', format('%.1fs', Time.now - started))

        text = Array(result['content']).map { |c|
          c.is_a?(Hash) && c['type'] == 'text' ? c['text'].to_s : nil
        }.compact.join("\n")

        structured = result['structuredContent']
        structured ||= begin
          parsed = JSON.parse(text)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end

        if result['isError']
          Kaitoio::Mcp.notify_tool(name, 'error', text[0, 120])
          raise Kaitoio::Error.new("MCP tool #{name} failed: #{text}", code: 'TOOL_ERROR')
        end

        { 'text' => text, 'structured' => structured, 'raw' => result }
      end

      # A short, non-secret summary of what the tool was asked to do.
      def tool_detail(name, args)
        return nil unless args.is_a?(Hash)
        args['node_type'] || args['query'] || args['execution_id'] || args['url']
      end

      # ---- transport -------------------------------------------------

      private

      def rpc(method, params)
        body = { 'jsonrpc' => '2.0', 'id' => SecureRandom.hex(8), 'method' => method }
        body['params'] = params if params
        payload = post(body)
        raise Kaitoio::Error.new("Empty MCP response for #{method}") unless payload

        if (err = payload['error'])
          raise error_for(err, method)
        end
        payload['result'] || {}
      end

      def notify(method, params = nil)
        body = { 'jsonrpc' => '2.0', 'method' => method }
        body['params'] = params if params
        post(body, expect_body: false)
      rescue Kaitoio::Error => e
        Kaitoio.log("MCP notify #{method} ignored: #{e.message}", 'WARN')
        nil
      end

      def post(body, expect_body: true)
        uri = URI.parse(@url)
        req = Net::HTTP::Post.new(uri)
        req['Authorization']        = "Bearer #{bearer}"
        req['Content-Type']         = 'application/json'
        req['Accept']               = 'application/json, text/event-stream'
        req['MCP-Protocol-Version'] = PROTOCOL_VERSION
        req['Mcp-Session-Id']       = @session_id if @session_id
        req['User-Agent']           = "kaitoi-sketchup/#{Kaitoio::VERSION}"
        req.body = JSON.generate(body)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == 'https'
        http.verify_mode  = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        res = http.start { |h| h.request(req) }
        # The server assigns the session on initialize and expects it back.
        sid = res['mcp-session-id']
        @session_id = sid if sid

        Kaitoio.log("MCP #{body['method']} -> #{res.code}")
        raise_http_error(res) unless res.is_a?(Net::HTTPSuccess)
        return nil unless expect_body

        decode(res)
      rescue Kaitoio::Error
        raise
      rescue => e
        raise Kaitoio::Error.new("MCP transport error: #{e.class}: #{e.message}")
      end

      # A Streamable HTTP server may answer with JSON or with an SSE stream
      # carrying the same JSON-RPC envelope in `data:` lines.
      def decode(res)
        raw = res.body.to_s
        return nil if raw.empty?

        if res['content-type'].to_s.include?('text/event-stream')
          payload = nil
          raw.each_line do |line|
            next unless line.start_with?('data:')
            chunk = line.sub(/\Adata:\s*/, '').strip
            next if chunk.empty? || chunk == '[DONE]'
            begin
              parsed = JSON.parse(chunk)
              payload = parsed if parsed.is_a?(Hash) && (parsed['result'] || parsed['error'])
            rescue JSON::ParserError
              next
            end
          end
          return payload
        end

        JSON.parse(raw)
      rescue JSON::ParserError
        raise Kaitoio::Error.new("Malformed MCP response: #{raw[0, 200]}")
      end

      def raise_http_error(res)
        detail = begin
          JSON.parse(res.body.to_s)
        rescue JSON::ParserError
          {}
        end
        code = detail.is_a?(Hash) ? ((detail['detail'] || {})['code'] || detail['error']) : nil
        msg  = detail.is_a?(Hash) ? (detail['error_description'] || detail['error'] || detail['detail']) : nil
        msg  = msg['message'] if msg.is_a?(Hash)
        msg ||= "HTTP #{res.code}"

        case res.code.to_i
        when 401
          # An expired OAuth session looks the same as a bad token; make the
          # remedy explicit rather than leaving "invalid_token".
          hint = if auth_mode == 'oauth'
                   ' Use Connect in the Agent panel to sign in again.'
                 else
                   ' Check the MCP token, or mint a fresh one in Kaitoi Studio > Settings > MCP.'
                 end
          raise Kaitoio::AuthError.new("#{msg}#{hint}", status: 401, code: code)
        when 403
          # The common case: a REST key without mcp:read / mcp:write.
          raise Kaitoio::AuthError.new(
            "#{msg} The MCP API needs mcp:read / mcp:write; a REST key does not carry " \
            'them. Mint an MCP token in Kaitoi Studio > Settings > MCP, or use Connect.',
            status: 403, code: code
          )
        when 404 then raise Kaitoio::NotFound.new(msg, status: 404, code: code)
        else raise Kaitoio::Error.new(msg, status: res.code.to_i, code: code)
        end
      end

      def error_for(err, method)
        msg  = err.is_a?(Hash) ? err['message'].to_s : err.to_s
        code = err.is_a?(Hash) ? err['code'] : nil
        Kaitoio::Error.new("MCP #{method}: #{msg}", code: code.to_s)
      end
    end
  end
end
