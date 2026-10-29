# frozen_string_literal: true

module Spinel
  module JVM
    # Lowers finite integer ranges to allocation-free counted loops.
    module RangeIteration
      private

      # Recognize an argument-free Range#each call with a literal range receiver and a block.
      def range_each?(node)
        receiver = node.dig("references", "receiver")
        node.dig("strings", "name") == "each" && receiver && receiver >= 0 &&
          @ir.node(receiver)["kind"] == "RangeNode" &&
          node.dig("references", "block").to_i >= 0 && call_arguments(node).empty?
      end

      # Inline a finite integer range as a counted loop in the enclosing JVM frame.
      # Evaluate endpoints once, isolate block locals, and avoid terminal-index overflow.
      def emit_range_each(node)
        range = @ir.node(node.dig("references", "receiver"))
        left, right = range.fetch("references").values_at("left", "right")
        unless [left, right].all? { |id| id && id >= 0 && node_type(@ir.node(id)) == "int" }
          unsupported!(range, "Range#each without finite integer bounds")
        end
        block = @ir.node(node.dig("references", "block"))
        require_kind!(block, "BlockNode")
        parameter = range_block_parameter(block)

        # Evaluate both endpoints exactly once, before entering the block's
        # lexical scope. The induction variable is independent of a writable
        # block parameter, and the terminal check avoids Long.MAX_VALUE wrap.
        current = @method.local(fresh_label("range_index").to_s, Java::long)
        limit = @method.local(fresh_label("range_limit").to_s, Java::long)
        emit_expression(left)
        @method.lstore(current)
        emit_expression(right)
        @method.lstore(limit)
        previous_locals = @locals
        @locals = @locals.dup
        block.dig("strings", "locals").to_s.split(",").each do |name|
          local = @scope.fetch("locals").find { |entry| entry["name"] == name }
          type = name == parameter ? "int" : effective_local_type(@scope, local)
          physical_type = jvm_type(type, name)
          @locals[name] = [@method.local(fresh_label("block_#{name}").to_s, physical_type), physical_type, type]
        end
        head = fresh_label("range_head")
        done = fresh_label("range_done")
        @method.label(head)
        @method.lload(current)
        @method.lload(limit)
        @method.lcmp
        @method.public_send(range.dig("integers", "flags").to_i.nobits?(4) ? :ifgt : :ifge, done)
        if parameter
          @method.lload(current)
          store_local(parameter)
        end
        body = block.dig("references", "body")
        emit_statements(body) if body && body >= 0
        @method.lload(current)
        @method.lload(limit)
        @method.lcmp
        @method.ifge(done)
        @method.lload(current)
        @method.ldc_long(1)
        @method.ladd
        @method.lstore(current)
        @method.goto(head)
        @method.label(done)
      ensure
        @locals = previous_locals if previous_locals
      end

      # Return the optional single required block parameter, rejecting other parameter layouts.
      def range_block_parameter(block)
        parameters = block.dig("references", "parameters")
        required = []
        if parameters && parameters >= 0
          parameters = @ir.node(parameters)
          require_kind!(parameters, "BlockParametersNode")
          parameters = parameters.dig("references", "parameters")
          if parameters && parameters >= 0
            parameters = @ir.node(parameters)
            require_kind!(parameters, "ParametersNode")
            required = parameters.fetch("arrays").fetch("requireds")
            other = parameters.fetch("arrays").except("requireds").values.flatten +
                    parameters.fetch("references").values.reject(&:negative?)
            unsupported!(block, "Range#each block parameter layout") unless required.length <= 1 && other.empty?
          end
        end
        unless required.empty?
          parameter_node = @ir.node(required.first)
          require_kind!(parameter_node, "RequiredParameterNode")
          return parameter_node.fetch("strings").fetch("name")
        end
        nil
      end
    end
  end
end
