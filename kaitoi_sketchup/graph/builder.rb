require 'securerandom'

module Kaitoio
  module Graph
    class Builder
      attr_reader :nodes, :connections

      def initialize
        @nodes       = []
        @connections = []
        @positions   = {}
      end

      def add_node(type:, id: nil, title: nil, inputs: {}, position: nil)
        id ||= SecureRandom.hex(6)
        @positions[id] ||= position || next_position
        node = {
          'id'       => id,
          'type'     => type,
          'inputs'   => deep_string_keys(inputs),
          'position' => @positions[id]
        }
        node['title'] = title if title
        @nodes << node
        id
      end

      def update_node_inputs(id, inputs)
        node = @nodes.find { |n| n['id'] == id }
        raise ArgumentError, "Unknown node id: #{id}" unless node
        node['inputs'] = deep_string_keys(inputs)
      end

      # Typed pin values, matching the REST contract:
      #   file pins  -> { "type" => "file",   "fileId" => "..." }
      #   value pins -> { "type" => "string", "value"  => "..." }
      def set_node_input(id, pin, value, type: nil)
        node = @nodes.find { |n| n['id'] == id }
        raise ArgumentError, "Unknown node id: #{id}" unless node
        node['inputs'] ||= {}
        node['inputs'][pin.to_s] = pin_value(value, type)
      end

      def set_file_input(id, pin, file_id)
        set_node_input(id, pin, file_id, type: 'file')
      end

      def pin_value(value, type)
        t = (type || 'string').to_s
        t == 'file' ? { 'type' => 'file', 'fileId' => value } : { 'type' => t, 'value' => value }
      end

      def connect(from_id, from_pin, to_id, to_pin)
        @connections << {
          'from' => [from_id, from_pin.to_s],
          'to'   => [to_id,   to_pin.to_s]
        }
      end

      def disconnect(from_id, from_pin, to_id, to_pin)
        @connections.reject! do |c|
          c['from'] == [from_id, from_pin.to_s] && c['to'] == [to_id, to_pin.to_s]
        end
      end

      def remove_node(id)
        @nodes.reject! { |n| n['id'] == id }
        @connections.reject! { |c| c['from'][0] == id || c['to'][0] == id }
        @positions.delete(id)
      end

      def to_graph
        {
          'nodes'       => @nodes.dup,
          'connections' => @connections.dup
        }
      end

      def replace_document_body(name:, metadata: nil, graph: nil)
        graph ||= to_graph
        {
          'name'     => name,
          'metadata' => metadata || {},
          'graph'    => graph
        }
      end

      def patch_ops
        ops = []
        @nodes.each { |n| ops << n.merge('op' => 'addNode') }
        ops
      end

      private

      def next_position
        idx = @nodes.length
        { 'x' => (idx % 4) * 280, 'y' => (idx / 4) * 200 }
      end

      def deep_string_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_string_keys(v) }
        when Array
          obj.map { |v| deep_string_keys(v) }
        else
          obj
        end
      end
    end
  end
end
