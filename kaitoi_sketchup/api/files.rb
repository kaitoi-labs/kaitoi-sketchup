require 'digest'
require 'fileutils'

require_relative 'client'

module Kaitoio
  module Api
    # File endpoints.
    #
    # Uploads use the direct-to-storage session flow, never the deprecated
    # 25 MB POST /files route:
    #   1. POST /files/uploads            -> signed upload instructions
    #   2. PUT bytes to upload.url        -> storage (no Bearer token!)
    #   3. POST /files/uploads/{id}/complete -> durable fileId
    class Files
      # Content types we can infer; anything else is sent as octet-stream and
      # the server sniffs it.
      MIME = {
        '.png'  => 'image/png',    '.jpg'  => 'image/jpeg',
        '.jpeg' => 'image/jpeg',   '.webp' => 'image/webp',
        '.gif'  => 'image/gif',    '.mp4'  => 'video/mp4',
        '.webm' => 'video/webm',   '.mov'  => 'video/quicktime',
        '.skp'  => 'application/octet-stream',
        '.json' => 'application/json', '.txt' => 'text/plain'
      }.freeze

      def initialize(client)
        @client = client
      end

      # Upload a local file and return its durable fileId.
      # Returns the completed file record (fileId, contentType, sizeBytes, ...).
      def upload(path, filename: nil, content_type: nil, external_id: nil,
                 external_user_id: nil, idempotency_key: nil)
        raise Kaitoio::Error.new("File not found: #{path}") unless File.file?(path)

        bytes    = File.binread(path)
        filename ||= File.basename(path)
        content_type ||= mime_for(path)
        sha256   = Digest::SHA256.hexdigest(bytes)

        session = create_upload_session(
          filename: filename, content_type: content_type,
          size_bytes: bytes.bytesize, sha256: sha256,
          external_id: external_id, external_user_id: external_user_id,
          idempotency_key: idempotency_key || SecureRandom.uuid
        )

        if session['storageMethod'].to_s == 'multipart'
          raise Kaitoio::Error.new(
            "File is too large for single-part upload (#{bytes.bytesize} bytes). " \
            'Multipart upload is not implemented in this plugin.'
          )
        end

        instructions = session['upload'] || {}
        Kaitoio.log("uploading #{filename} (#{bytes.bytesize} bytes, #{content_type})")
        @client.put_signed(instructions['url'], bytes, instructions['headers'] || {})

        complete_upload(session['uploadId'], size_bytes: bytes.bytesize, sha256: sha256)
      end

      def create_upload_session(filename:, content_type:, size_bytes:, sha256: nil,
                                external_id: nil, external_user_id: nil, idempotency_key: nil)
        body = {
          'filename'    => filename,
          'contentType' => content_type,
          'sizeBytes'   => size_bytes
        }
        body['sha256']         = sha256           if sha256
        body['externalId']     = external_id      if external_id
        body['externalUserId'] = external_user_id if external_user_id
        @client.post('/files/uploads', body: body, idempotency_key: idempotency_key)
      end

      def complete_upload(upload_id, size_bytes: nil, sha256: nil)
        body = {}
        body['actualSizeBytes'] = size_bytes if size_bytes
        body['actualSha256']    = sha256     if sha256
        @client.post("/files/uploads/#{upload_id}/complete", body: body)
      end

      def abort_upload(upload_id)
        @client.delete("/files/uploads/#{upload_id}")
        true
      end

      def get(file_id)
        @client.get("/files/#{file_id}")
      end

      def delete(file_id, external_user_id: nil)
        q = external_user_id ? { 'externalUserId' => external_user_id } : nil
        @client.delete("/files/#{file_id}", query: q)
        true
      end

      # Short-lived signed URL. Do not persist it; ask again when it expires.
      def download_url(file_id, expires_in_seconds: 3600)
        @client.get("/files/#{file_id}/download-url",
                    query: { 'expiresInSeconds' => expires_in_seconds })
      end

      # Fetch a file's bytes to disk, resolving the signed URL first.
      def download(file_id, dest_path: nil, expires_in_seconds: 3600)
        info = download_url(file_id, expires_in_seconds: expires_in_seconds)
        url  = info['url'] || info['downloadUrl']
        raise Kaitoio::Error.new("No download URL returned for #{file_id}") unless url

        dest_path ||= File.join(Kaitoio::Settings.download_dir,
                                info['filename'] || File.basename(file_id.to_s))
        @client.download_to(url, dest_path)
      end

      def mime_for(path)
        MIME[File.extname(path).downcase] || 'application/octet-stream'
      end
    end
  end
end
