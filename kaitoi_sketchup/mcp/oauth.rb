require 'net/http'
require 'uri'
require 'json'
require 'socket'
require 'digest'
require 'base64'
require 'securerandom'
require 'fileutils'

require_relative '../api/errors'

module Kaitoio
  module Mcp
    # OAuth 2.1 authorization-code + PKCE against the Kaitoi MCP
    # authorization server.
    #
    # The MCP endpoint does not accept Kaitoi REST API keys -- it advertises
    # scopes mcp:read / mcp:write and rejects static keys with invalid_token.
    # The client is registered dynamically (public client, no secret), so
    # nothing has to be provisioned by hand.
    #
    # The callback is caught by a tiny loopback listener polled from
    # UI.start_timer; SketchUp will not reliably schedule a background thread,
    # and blocking on accept would freeze the UI.
    module OAuth
      PORTS = [8785, 8786, 8787, 8788].freeze
      REDIRECT_PATH = '/callback'.freeze

      module_function

      # ---- token storage ---------------------------------------------

      def path
        dir = File.join(ENV['HOME'], '.kaitoi_sketchup')
        FileUtils.mkdir_p(dir)
        File.join(dir, 'mcp_auth.json')
      end

      def store
        return {} unless File.exist?(path)
        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : {}
      rescue JSON::ParserError
        {}
      end

      def save(values)
        merged = store.merge(values)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(JSON.pretty_generate(merged))
        end
        merged
      end

      def forget!
        File.delete(path) if File.exist?(path)
        true
      rescue
        false
      end

      def signed_in?
        !store['refresh_token'].to_s.empty? || !access_token_raw.to_s.empty?
      end

      def access_token_raw
        store['access_token']
      end

      def expired?
        exp = store['expires_at'].to_i
        exp.zero? ? false : Time.now.to_i >= (exp - 60)
      end

      # Valid access token, refreshed if needed. nil when sign-in is required.
      def access_token
        return nil unless signed_in?
        return refresh! if expired?
        access_token_raw
      end

      # ---- server metadata -------------------------------------------

      def resource_url
        Kaitoio::Settings.load['mcp_url'].to_s
      end

      def metadata
        @metadata ||= begin
          res  = get_json(well_known(resource_url, 'oauth-protected-resource'))
          issuer = Array(res['authorization_servers']).first
          raise Kaitoio::Error.new('MCP server advertises no authorization server') unless issuer
          @scopes = Array(res['scopes_supported'])
          discover(issuer)
        end
      end

      def scopes
        metadata
        (@scopes && !@scopes.empty? ? @scopes : %w[mcp:read mcp:write]).join(' ')
      end

      # RFC 8414 puts the path suffix after .well-known; some servers instead
      # serve it under the issuer path. Try both.
      def discover(issuer)
        get_json(well_known(issuer, 'oauth-authorization-server'))
      rescue Kaitoio::Error
        u = URI.parse(issuer)
        u.path = "#{u.path.to_s.chomp('/')}/.well-known/oauth-authorization-server"
        get_json(u.to_s)
      end

      # RFC 8414 puts the suffix after .well-known, before any path.
      def well_known(base, doc)
        uri = URI.parse(base.to_s)
        prefix = uri.path.to_s.chomp('/')
        uri.path = "/.well-known/#{doc}#{prefix}"
        uri.to_s
      end

      # ---- sign-in ----------------------------------------------------

      # Binds the loopback listener, registers a client for that exact
      # redirect_uri, and returns the URL the user must approve.
      def begin_sign_in
        @server = nil
        port = PORTS.find do |p|
          begin
            @server = TCPServer.new('127.0.0.1', p)
          rescue Errno::EADDRINUSE, Errno::EACCES
            nil
          end
        end
        raise Kaitoio::Error.new("No free loopback port in #{PORTS.inspect}") unless @server

        redirect_uri = "http://127.0.0.1:#{port}#{REDIRECT_PATH}"
        client_id    = client_for(redirect_uri)

        @verifier = b64(SecureRandom.random_bytes(32))
        @state    = SecureRandom.hex(16)
        challenge = b64(Digest::SHA256.digest(@verifier))
        @redirect_uri = redirect_uri

        query = {
          'response_type'         => 'code',
          'client_id'             => client_id,
          'redirect_uri'          => redirect_uri,
          'scope'                 => scopes,
          'state'                 => @state,
          'code_challenge'        => challenge,
          'code_challenge_method' => 'S256',
          'resource'              => resource_url
        }
        url = "#{metadata['authorization_endpoint']}?#{URI.encode_www_form(query)}"
        Kaitoio.log("MCP sign-in listening on #{redirect_uri}")
        url
      end

      # Reuse a registered client only if it matches this redirect_uri.
      def client_for(redirect_uri)
        s = store
        return s['client_id'] if s['client_id'] && s['redirect_uri'] == redirect_uri

        res = post_json(metadata['registration_endpoint'], {
          'client_name'                => 'Kaitoi SketchUp Agent',
          'redirect_uris'              => [redirect_uri],
          'grant_types'                => %w[authorization_code refresh_token],
          'response_types'             => ['code'],
          'token_endpoint_auth_method' => 'none',
          'scope'                      => scopes
        })
        id = res['client_id']
        raise Kaitoio::Error.new("Client registration failed: #{res.inspect[0, 200]}") unless id
        save('client_id' => id, 'redirect_uri' => redirect_uri)
        id
      end

      # Polled from a timer. :pending until the browser redirect arrives.
      def pump
        return :idle unless @server

        begin
          sock = @server.accept_nonblock
        rescue IO::WaitReadable, Errno::EINTR
          return :pending
        end

        line = sock.gets.to_s
        params = {}
        if (m = line.match(%r{GET\s+(\S+)\s+HTTP}))
          q = URI.parse(m[1]).query
          params = q ? Hash[URI.decode_www_form(q)] : {}
        end

        body = if params['code'] && params['state'] == @state
                 'Kaitoi Agent is connected. You can close this tab.'
               else
                 "Sign-in failed: #{params['error'] || 'no authorization code'}"
               end
        sock.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        sock.close rescue nil
        stop_listener

        unless params['code'] && params['state'] == @state
          raise Kaitoio::Error.new("MCP sign-in failed: #{params['error'] || 'state mismatch or no code'}")
        end

        exchange(params['code'])
        :done
      end

      def stop_listener
        @server.close if @server
      rescue
        nil
      ensure
        @server = nil
      end

      def exchange(code)
        res = post_form(metadata['token_endpoint'], {
          'grant_type'    => 'authorization_code',
          'code'          => code,
          'redirect_uri'  => @redirect_uri,
          'client_id'     => store['client_id'],
          'code_verifier' => @verifier,
          'resource'      => resource_url
        })
        persist_tokens(res)
        Kaitoio.log('MCP sign-in complete')
        res['access_token']
      end

      def refresh!
        rt = store['refresh_token'].to_s
        raise Kaitoio::Error.new('MCP session expired; sign in again') if rt.empty?

        res = post_form(metadata['token_endpoint'], {
          'grant_type'    => 'refresh_token',
          'refresh_token' => rt,
          'client_id'     => store['client_id'],
          'resource'      => resource_url
        })
        persist_tokens(res)
        res['access_token']
      rescue Kaitoio::Error
        raise
      rescue => e
        raise Kaitoio::Error.new("MCP token refresh failed: #{e.message}")
      end

      def persist_tokens(res)
        raise Kaitoio::Error.new("Token endpoint returned no access_token: #{res.inspect[0, 200]}") unless res['access_token']
        save(
          'access_token'  => res['access_token'],
          'refresh_token' => res['refresh_token'] || store['refresh_token'],
          'expires_at'    => Time.now.to_i + (res['expires_in'] || 3600).to_i,
          'scope'         => res['scope']
        )
      end

      # ---- tiny HTTP helpers -----------------------------------------

      def b64(bytes)
        Base64.urlsafe_encode64(bytes).delete('=')
      end

      def get_json(url)
        request(Net::HTTP::Get, url)
      end

      def post_json(url, body)
        request(Net::HTTP::Post, url) do |req|
          req['Content-Type'] = 'application/json'
          req.body = JSON.generate(body)
        end
      end

      def post_form(url, form)
        request(Net::HTTP::Post, url) do |req|
          req.set_form_data(form)
        end
      end

      def request(klass, url)
        uri = URI.parse(url)
        req = klass.new(uri)
        req['Accept'] = 'application/json'
        yield req if block_given?

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = uri.scheme == 'https'
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = 30
        http.read_timeout = 30
        res = http.start { |h| h.request(req) }

        parsed = begin
          JSON.parse(res.body.to_s)
        rescue JSON::ParserError
          {}
        end
        unless res.is_a?(Net::HTTPSuccess)
          msg = parsed['error_description'] || parsed['error'] || "HTTP #{res.code}"
          raise Kaitoio::Error.new("OAuth #{uri.path}: #{msg}", status: res.code.to_i)
        end
        parsed
      end
    end
  end
end
