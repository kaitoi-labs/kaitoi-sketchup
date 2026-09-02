require 'net/http'
require 'uri'
require 'json'
require 'securerandom'
require 'fileutils'

require_relative 'errors'

module Kaitoio
  module Api
    # Thin Net::HTTP wrapper for the Kaitoi REST API.
    #
    # Responsibilities kept here (and nowhere else) so the rest of the plugin
    # never touches HTTP directly:
    #   - Bearer auth, JSON encode/decode
    #   - retry with backoff on 429 / 5xx / transient socket errors
    #   - mapping the API's { "error": { code, message, details } } envelope
    #     onto the Kaitoio::Error subclasses in errors.rb
    #
    # The Bearer token never leaves Ruby: the HTML panel calls Ruby action
    # callbacks, and Ruby calls this client.
    class Client
      IDEMPOTENT_METHODS = %w[GET HEAD PUT DELETE PATCH].freeze
      RETRIABLE_STATUS   = [429, 500, 502, 503, 504].freeze
      RETRIABLE_ERRORS   = [
        Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE,
        Errno::EHOSTUNREACH, EOFError, SocketError, IOError
      ].freeze
      MAX_BACKOFF = 15

      attr_reader :base_url, :timeout, :max_retries

      def initialize(base_url: nil, api_key: nil, timeout: nil, max_retries: nil)
        cfg          = Kaitoio::Settings.load
        @base_url    = (base_url || Kaitoio::Settings.api_base).to_s.chomp('/')
        @api_key     = (api_key  || cfg['api_key']).to_s
        @timeout     = (timeout     || cfg['request_timeout_seconds'] || 120).to_i
        @max_retries = (max_retries || cfg['max_retries'] || 3).to_i
      end

      def configured?
        !@api_key.empty? && !@base_url.empty?
      end

      # ---- verbs -------------------------------------------------------

      def get(path, query: nil, raw: false, headers: nil)
        request('GET', path, query: query, raw: raw, headers: headers)
      end

      def post(path, body: nil, query: nil, idempotency_key: nil, raw: false)
        request('POST', path, body: body, query: query, raw: raw,
                              idempotency_key: idempotency_key)
      end

      def put(path, body: nil, query: nil, idempotency_key: nil)
        request('PUT', path, body: body, query: query, idempotency_key: idempotency_key)
      end

      def patch(path, body: nil, query: nil, idempotency_key: nil)
        request('PATCH', path, body: body, query: query, idempotency_key: idempotency_key)
      end

      def delete(path, query: nil)
        request('DELETE', path, query: query)
      end

      def account_credits
        get('/account/credits')
      end

      # ---- signed-URL helpers (no Bearer token!) -----------------------

      # PUT raw bytes to a storage-signed URL. The signed URL *is* the
      # credential; sending our Bearer token there would leak it to storage.
      def put_signed(url, bytes, headers = {})
        uri = URI.parse(url)
        req = Net::HTTP::Put.new(uri)
        headers.each { |k, v| req[k.to_s] = v.to_s }
        req.body = bytes
        res = perform(uri, req, 'PUT', url)
        unless res.is_a?(Net::HTTPSuccess)
          raise Kaitoio::Error.new("Signed upload failed (#{res.code})", status: res.code.to_i)
        end
        res['etag']
      end

      # Download a signed URL straight to disk. Follows redirects.
      def download_to(url, dest_path, limit = 5)
        raise Kaitoio::Error.new('Too many redirects while downloading') if limit <= 0
        uri = URI.parse(url)
        req = Net::HTTP::Get.new(uri)
        res = perform(uri, req, 'GET', url)

        if res.is_a?(Net::HTTPRedirection) && res['location']
          return download_to(res['location'], dest_path, limit - 1)
        end
        unless res.is_a?(Net::HTTPSuccess)
          raise Kaitoio::Error.new("Download failed (#{res.code})", status: res.code.to_i)
        end

        FileUtils.mkdir_p(File.dirname(dest_path))
        File.binwrite(dest_path, res.body)
        { 'path' => dest_path, 'contentType' => res['content-type'], 'sizeBytes' => res.body.bytesize }
      end

      # ---- core --------------------------------------------------------

      private

      def request(method, path, body: nil, query: nil, raw: false, headers: nil, idempotency_key: nil)
        uri = build_uri(path, query)
        attempt = 0

        begin
          attempt += 1
          req = build_request(method, uri, body, headers, idempotency_key)
          started = Time.now
          res = perform(uri, req, method, uri.to_s)
          log_http(method, uri, res, Time.now - started, attempt)

          if retriable?(res, method, idempotency_key) && attempt <= @max_retries
            sleep(backoff_for(res, attempt))
            raise Retry
          end

          handle(res, raw)
        rescue Retry
          retry
        rescue *RETRIABLE_ERRORS => e
          if attempt <= @max_retries && (IDEMPOTENT_METHODS.include?(method) || idempotency_key)
            Kaitoio.log("#{method} #{uri.path} transient #{e.class}, retry #{attempt}/#{@max_retries}", 'WARN')
            sleep(backoff_for(nil, attempt))
            retry
          end
          raise Kaitoio::Error.new("Network error: #{e.class}: #{e.message}")
        end
      end

      # Internal sentinel so the retry path shares one rescue site.
      class Retry < StandardError; end
      private_constant :Retry

      def build_uri(path, query)
        raw_path = path.to_s
        url = raw_path.start_with?('http') ? raw_path : "#{@base_url}#{raw_path.start_with?('/') ? '' : '/'}#{raw_path}"
        uri = URI.parse(url)
        if query && !query.empty?
          merged = URI.decode_www_form(uri.query || '')
          query.each { |k, v| merged << [k.to_s, v.to_s] unless v.nil? }
          uri.query = URI.encode_www_form(merged)
        end
        uri
      end

      def build_request(method, uri, body, headers, idempotency_key)
        klass = case method
                when 'GET'    then Net::HTTP::Get
                when 'POST'   then Net::HTTP::Post
                when 'PUT'    then Net::HTTP::Put
                when 'PATCH'  then Net::HTTP::Patch
                when 'DELETE' then Net::HTTP::Delete
                else raise ArgumentError, "Unsupported method #{method}"
                end
        req = klass.new(uri)
        req['Authorization'] = "Bearer #{@api_key}" unless @api_key.empty?
        req['Accept']        = 'application/json'
        req['User-Agent']    = "kaitoi-sketchup/#{Kaitoio::VERSION}"
        req['Idempotency-Key'] = idempotency_key if idempotency_key
        (headers || {}).each { |k, v| req[k.to_s] = v.to_s }
        if body
          req['Content-Type'] = 'application/json'
          req.body = JSON.generate(body)
        end
        req
      end

      def perform(uri, req, method, label)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == 'https'
        http.verify_mode  = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.start { |h| h.request(req) }
      rescue *RETRIABLE_ERRORS
        raise
      rescue => e
        raise Kaitoio::Error.new("#{method} #{label} failed: #{e.class}: #{e.message}")
      end

      def retriable?(res, method, idempotency_key)
        return false unless RETRIABLE_STATUS.include?(res.code.to_i)
        IDEMPOTENT_METHODS.include?(method) || !idempotency_key.nil?
      end

      # 429 carries Retry-After; everything else uses exponential backoff
      # with jitter so a burst of panel actions doesn't resonate.
      def backoff_for(res, attempt)
        if res && res['retry-after']
          after = res['retry-after'].to_f
          return [after, MAX_BACKOFF].min if after > 0
        end
        [(2**(attempt - 1)) + rand, MAX_BACKOFF].min
      end

      def handle(res, raw)
        status = res.code.to_i
        return nil if status == 204
        raise_api_error(res, status) unless res.is_a?(Net::HTTPSuccess)
        return res.body if raw
        return nil if res.body.nil? || res.body.empty?

        JSON.parse(res.body)
      rescue JSON::ParserError
        raise Kaitoio::Error.new('Malformed JSON in API response', status: status,
                                 request_id: request_id(res))
      end

      def raise_api_error(res, status)
        code = nil
        message = "HTTP #{status}"
        details = nil
        begin
          parsed = JSON.parse(res.body.to_s)
          if parsed.is_a?(Hash) && parsed['error'].is_a?(Hash)
            err     = parsed['error']
            code    = err['code']
            message = err['message'] || message
            details = err['details']
          end
        rescue JSON::ParserError
          message = res.body.to_s[0, 300] unless res.body.to_s.empty?
        end

        klass = error_class_for(status, code)
        raise klass.new(message, status: status, code: code, details: details,
                        request_id: request_id(res))
      end

      def error_class_for(status, code)
        return Kaitoio::FileInUse if code.to_s.upcase.include?('FILE_IN_USE')

        case status
        when 401, 403 then Kaitoio::AuthError
        when 404      then Kaitoio::NotFound
        when 409      then Kaitoio::VersionConflict
        when 400, 422 then Kaitoio::ValidationError
        when 429      then Kaitoio::RateLimited
        else Kaitoio::Error
        end
      end

      def request_id(res)
        res['x-request-id'] || res['x-kaitoi-request-id'] || res['request-id']
      end

      def log_http(method, uri, res, elapsed, attempt)
        line = format('%s %s -> %s (%.2fs)', method, uri.path, res.code, elapsed)
        line += " attempt=#{attempt}" if attempt > 1
        rid = request_id(res)
        line += " req=#{rid}" if rid
        Kaitoio.log(line, res.is_a?(Net::HTTPSuccess) ? 'INFO' : 'WARN')
      end
    end
  end
end
