# frozen_string_literal: true

require "json"
require_relative "invalid_ir"

module Spinel
  module JVM
    # Reads and validates the versioned analyzed IR and lexical syntax tables.
    class IR
      FORMAT = "SPINEL-ANALYZED-IR"
      VERSION = 1

      # Expose validated IR metadata and its immutable ID indexes.
      attr_reader :data, :nodes, :scopes, :classes

      # Read analyzed IR JSON from disk, reporting parse errors with the input path.
      def self.load(path)
        new(JSON.parse(File.binread(path)), path)
      rescue JSON::ParserError => error
        raise InvalidIR, "#{path}: invalid JSON: #{error.message}"
      end

      # Validate the schema and build indexed node/scope/class tables before checking all references.
      def initialize(data, source = "<memory>")
        @data = data
        @source = source
        validate_header!
        @nodes = indexed_table!("nodes")
        @scopes = indexed_table!("scopes")
        @classes = indexed_table!("classes")
        validate_references!
        validate_syntax!
      end

      # Return the validated root node ID from the analyzed IR header.
      def root
        fetch_integer(@data, "root", "root")
      end

      # Fetch an analyzed node by ID, raising InvalidIR when the reference is missing.
      def node(id)
        @nodes.fetch(id) { raise InvalidIR, "#{@source}: missing node #{id}" }
      end

      # Fetch analyzed scope metadata by ID, raising InvalidIR for a missing scope.
      def scope(id)
        @scopes.fetch(id) { raise InvalidIR, "#{@source}: missing scope #{id}" }
      end

      private

      # Require the analyzed-IR format marker and the supported schema version.
      def validate_header!
        raise InvalidIR, "#{@source}: expected #{FORMAT}" unless @data.is_a?(Hash) && @data["format"] == FORMAT

        version = @data["version"]
        return if version == VERSION

        raise InvalidIR,
              "#{@source}: unsupported analyzed IR version #{version.inspect}; " \
              "expected #{VERSION}"
      end

      # Index table entries by unique integer IDs and freeze the resulting entries and map.
      def indexed_table!(name)
        entries = @data[name]
        raise InvalidIR, "#{@source}: #{name} must be an array" unless entries.is_a?(Array)

        entries.each_with_object({}) do |entry, table|
          unless entry.is_a?(Hash) && entry["id"].is_a?(Integer)
            raise InvalidIR, "#{@source}: #{name} entry lacks an integer id"
          end

          id = entry["id"]
          raise InvalidIR, "#{@source}: duplicate #{name} id #{id}" if table.key?(id)

          table[id] = entry.freeze
        end.freeze
      end

      # Require node analysis, valid scope IDs, and resolvable direct/array child references.
      def validate_references!
        node(root)
        @nodes.each_value do |entry|
          analysis = entry["analysis"]
          raise InvalidIR, "#{@source}: node #{entry["id"]} lacks analysis" unless analysis.is_a?(Hash)

          scope_id = fetch_integer(analysis, "scope", "node #{entry["id"]} scope")
          scope(scope_id)
          references = entry["references"] || {}
          arrays = entry["arrays"] || {}
          references.each_value { |id| node(id) unless id == -1 }
          arrays.each_value do |ids|
            raise InvalidIR, "#{@source}: node array must be an array" unless ids.is_a?(Array)

            ids.each { |id| node(id) }
          end
        end
      end

      # Read an integer field or report a schema error using the supplied field description.
      def fetch_integer(hash, key, description)
        value = hash[key]
        return value if value.is_a?(Integer)

        raise InvalidIR, "#{@source}: #{description} must be an integer"
      end

      # Validate the optional lexical syntax table, its unique node IDs, root, and child references.
      def validate_syntax!
        syntax = @data["syntax"]
        return unless syntax
        unless syntax.is_a?(Hash) && syntax["nodes"].is_a?(Array) && syntax["root"].is_a?(Integer)
          raise InvalidIR, "#{@source}: invalid lexical syntax table"
        end

        nodes = {}
        syntax["nodes"].each do |node|
          unless node.is_a?(Hash) && node["id"].is_a?(Integer) && node["kind"].is_a?(String) && !nodes.key?(node["id"])
            raise InvalidIR, "#{@source}: invalid or duplicate lexical syntax node"
          end

          nodes[node["id"]] = node
        end
        references = [syntax["root"]]
        nodes.each_value do |node|
          references.concat(node.fetch("references", {}).values.reject { |id| id == -1 })
          node.fetch("arrays", {}).each_value do |array|
            raise InvalidIR, "#{@source}: lexical syntax node array must be an array" unless array.is_a?(Array)

            references.concat(array)
          end
        end
        return if references.all? { |id| id.is_a?(Integer) && nodes.key?(id) }

        raise InvalidIR, "#{@source}: missing lexical syntax node"
      end
    end
  end
end
