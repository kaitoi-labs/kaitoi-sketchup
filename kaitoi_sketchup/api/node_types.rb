require_relative 'client'

module Kaitoio
  module Api
    class NodeTypes
      def initialize(client)
        @client = client
      end

      def list(limit: 50, cursor: nil, search: nil)
        q = { 'limit' => limit }
        q['cursor'] = cursor if cursor
        q['search'] = search if search
        @client.get('/node-types', query: q)
      end

      def get(node_type)
        @client.get("/node-types/#{URI.encode_www_form_component(node_type)}")
      end

      def thumbnail(node_type, index: 1, token: nil, dest_path: nil)
        token ||= @client.get("/node-types/#{URI.encode_www_form_component(node_type)}")['thumbnailUrl']
        raise Kaitoio::Error.new('No thumbnailUrl/token for node type') unless token
        url = "/node-type-thumbnails/#{URI.encode_www_form_component(node_type)}?token=#{URI.encode_www_form_component(token)}&index=#{index}"
        bytes = @client.get(url, raw: true)
        dest_path ||= File.join(Kaitoio::Settings.download_dir, "#{node_type.gsub('/', '_')}_#{index}.png")
        FileUtils.mkdir_p(File.dirname(dest_path))
        File.binwrite(dest_path, bytes)
        dest_path
      end
    end
  end
end
