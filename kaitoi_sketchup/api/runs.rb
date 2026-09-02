require 'securerandom'

require_relative 'client'

module Kaitoio
  module Api
    # Run endpoints: inline transient graphs and saved-project runs.
    #
    # SketchUp cannot reliably schedule background Ruby threads, so nothing
    # here blocks by default. The dialog drives `get` / `events` from a
    # UI.start_timer tick; `poll_until_done` is the blocking variant for
    # scripting from the Ruby Console.
    class Runs
      TERMINAL = %w[succeeded failed canceled cancelled].freeze

      def initialize(client)
        @client = client
      end

      # Exactly one of graph: / project_id: must be given.
      def create(graph: nil, project_id: nil, target_node_ids: nil,
                 input_overrides: nil, external_user_id: nil, idempotency_key: nil)
        if (graph.nil? && project_id.nil?) || (graph && project_id)
          raise ArgumentError, 'Provide exactly one of graph: or project_id:'
        end

        body = {}
        body['graph']           = graph            if graph
        body['projectId']       = project_id       if project_id
        body['targetNodeIds']   = Array(target_node_ids) if target_node_ids
        body['inputOverrides']  = input_overrides  if input_overrides
        body['externalUserId']  = external_user_id if external_user_id

        @client.post('/runs', body: body, idempotency_key: idempotency_key || SecureRandom.uuid)
      end

      def get(run_id)
        @client.get("/runs/#{run_id}")
      end

      def cancel(run_id)
        @client.post("/runs/#{run_id}/cancel")
      end

      # Lifecycle / progress / log events. Pass the previous response's cursor
      # to get only what is new — this is what drives the panel's progress
      # line without hammering the full run record.
      def events(run_id, cursor: nil, limit: nil)
        q = {}
        q['cursor'] = cursor if cursor
        q['limit']  = limit  if limit
        @client.get("/runs/#{run_id}/events", query: q.empty? ? nil : q)
      end

      def apply_to_project(run_id, expected_version: nil, idempotency_key: nil)
        body = {}
        body['expectedVersion'] = expected_version if expected_version
        @client.post("/runs/#{run_id}/apply-to-project", body: body,
                     idempotency_key: idempotency_key)
      end

      def terminal?(run)
        TERMINAL.include?(run['status'].to_s)
      end

      def succeeded?(run)
        run['status'].to_s == 'succeeded'
      end

      # Blocking poll. Only for the Ruby Console / scripts — the panel uses
      # UI.start_timer so the UI stays responsive.
      def poll_until_done(run_id, interval: nil, timeout: 900)
        interval ||= (Kaitoio::Settings.load['poll_interval_seconds'] || 2).to_i
        deadline = Time.now + timeout
        loop do
          run = get(run_id)
          return run if terminal?(run)
          if Time.now > deadline
            raise Kaitoio::Error.new("Run #{run_id} did not finish within #{timeout}s (status=#{run['status']})")
          end
          sleep(interval)
        end
      end

      # Pull the first file-ish output out of a run record.
      # Outputs look like { "outputImage" => { "type"=>"file", "fileId"=>..,
      #   "contentType"=>.., "downloadUrl"=>.., "filename"=>.. } }
      def first_file_output(run)
        outputs = run['outputs']
        return nil unless outputs.is_a?(Hash)
        outputs.each_value do |v|
          next unless v.is_a?(Hash)
          return v if v['fileId'] || v['downloadUrl']
        end
        nil
      end
    end
  end
end
