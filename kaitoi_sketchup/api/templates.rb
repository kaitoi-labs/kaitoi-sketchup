require_relative 'client'

module Kaitoio
  module Api
    # Template endpoints: published, runnable projects whose inputs are
    # declared (name + type), so binding the viewport image + prompt is
    # explicit instead of guessed from a raw graph.
    class Templates
      def initialize(client)
        @client = client
      end

      def list(limit: 100, cursor: nil, search: nil)
        q = { 'limit' => limit }
        q['cursor'] = cursor if cursor
        q['search'] = search if search
        @client.get('/templates', query: q)
      end

      def get(template_id)
        @client.get("/templates/#{template_id}")
      end

      def endpoints(template_id)
        @client.get("/templates/#{template_id}/endpoints")
      end

      def docs(template_id, endpoint_id)
        @client.get("/templates/#{template_id}/endpoints/#{endpoint_id}/docs")
      end

      def create_run(template_id, endpoint_id, inputs:)
        @client.post("/templates/#{template_id}/endpoints/#{endpoint_id}/runs",
                     body: { 'inputs' => inputs })
      end

      def get_run(template_id, endpoint_id, task_id)
        @client.get("/templates/#{template_id}/endpoints/#{endpoint_id}/runs/#{task_id}")
      end
    end
  end
end
