require_relative 'client'

module Kaitoio
  module Api
    class Projects
      def initialize(client)
        @client = client
      end

      def create(name:, external_id: nil, external_user_id: nil, external_workspace_id: nil, metadata: nil, idempotency_key: nil)
        body = { 'name' => name }
        body['externalId']          = external_id          if external_id
        body['externalUserId']      = external_user_id     if external_user_id
        body['externalWorkspaceId'] = external_workspace_id if external_workspace_id
        body['metadata']            = metadata             if metadata
        @client.post('/projects', body: body, idempotency_key: idempotency_key)
      end

      def list(limit: 50, cursor: nil, external_id: nil, external_user_id: nil, external_workspace_id: nil, search: nil)
        q = { 'limit' => limit }
        q['cursor']              = cursor              if cursor
        q['externalId']          = external_id         if external_id
        q['externalUserId']      = external_user_id    if external_user_id
        q['externalWorkspaceId'] = external_workspace_id if external_workspace_id
        q['search']              = search              if search
        @client.get('/projects', query: q)
      end

      def get(project_id)
        @client.get("/projects/#{project_id}")
      end

      def update(project_id, expected_version:, name: nil, metadata: nil, external_id: nil, external_user_id: nil, external_workspace_id: nil)
        body = { 'expectedVersion' => expected_version }
        body['name']                = name                if name
        body['metadata']            = metadata            unless metadata.nil?
        body['externalId']          = external_id         if external_id
        body['externalUserId']      = external_user_id    if external_user_id
        body['externalWorkspaceId'] = external_workspace_id if external_workspace_id
        @client.patch("/projects/#{project_id}", body: body)
      end

      def update_metadata(project_id, expected_version:, metadata:)
        @client.patch("/projects/#{project_id}/metadata", body: { 'expectedVersion' => expected_version, 'metadata' => metadata })
      end

      def delete(project_id, expected_version:)
        @client.delete("/projects/#{project_id}", query: { 'expectedVersion' => expected_version })
        true
      end

      def graph(project_id)
        @client.get("/projects/#{project_id}/graph")
      end

      def document(project_id)
        @client.get("/projects/#{project_id}/document")
      end

      def replace_document(project_id, expected_version:, document:, idempotency_key: nil)
        @client.put("/projects/#{project_id}/document",
                    body: { 'expectedVersion' => expected_version, 'document' => document },
                    idempotency_key: idempotency_key)
      end

      def patch_document(project_id, expected_version:, operations:, idempotency_key: nil)
        raise ArgumentError, 'operations must be an Array of 1..100' unless operations.is_a?(Array) && !operations.empty? && operations.length <= 100
        @client.patch("/projects/#{project_id}/document",
                      body: { 'expectedVersion' => expected_version, 'operations' => operations },
                      idempotency_key: idempotency_key)
      end

      def spend(project_id)
        @client.get("/projects/#{project_id}/spend")
      end
    end
  end
end
