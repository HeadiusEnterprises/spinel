# frozen_string_literal: true

require_relative "runtime_support"

module Spinel
  module JVM
    # Emits boxed values and lexical closures as JVM methods.
    class CoreCompiler
      MAIN = "org/spinel/generated/SpinelMain"
      CORE = :"org/spinel/runtime/Core"
      ENVIRONMENT = :"org/spinel/runtime/Core$Environment"
      BLOCK = :"org/spinel/runtime/Core$Block"
      PROGRAM = :"org/spinel/runtime/Core$Program"
      OBJECT = Java::java.lang.Object
      OBJECT_ARRAY = Java::java.lang.Object[]
      STRING = Java::java.lang.String
      PRIMITIVE_NODE_KINDS = %w[
        ProgramNode StatementsNode IntegerNode FloatNode StringNode TrueNode FalseNode
        LocalVariableReadNode LocalVariableWriteNode InstanceVariableReadNode InstanceVariableWriteNode
        CallNode ArgumentsNode DefNode ClassNode ConstantReadNode ParametersNode RequiredParameterNode
        IfNode UnlessNode ElseNode WhileNode UntilNode SelfNode ParenthesesNode
      ].freeze
      JAVA_CALL_NAMES = %w[
        java_import java_signature java_send java_package java_interface java_abstract java_record java_enum
      ].freeze
      BINARY_OPERATORS = %w[+ - * / % & | ^ << >> ** < <= > >= == !=].freeze
      LOCAL_WRITE_NODES = %w[
        LocalVariableWriteNode LocalVariableOperatorWriteNode LocalVariableTargetNode
        LocalVariableOrWriteNode LocalVariableAndWriteNode
      ].freeze
      # One source body and its argument/slot layout.
      CompilationUnit = Struct.new(:id, :body, :parameters, :scope, :block, :node_id)
      # Resolves captured locals as a parent depth and slot index.
      LexicalScope = Struct.new(:slots, :parent) do
        # Return a captured local's parent depth and slot index, or reject an unbound name.
        def resolve_binding(name, depth = 0)
          return [depth, slots.fetch(name)] if slots.key?(name)
          return parent.resolve_binding(name, depth + 1) if parent

          raise UnsupportedNode, "unbound JVM local #{name}"
        end
      end

      # Select boxed lowering when syntax, local types, or calls exceed the primitive subset.
      # Java-enabled programs stay on the separate Java-ABI path.
      def self.required?(analyzed_ir)
        return false unless analyzed_ir.data["syntax"]
        return false if analyzed_ir.data.fetch("features", []).include?("java")
        return false if analyzed_ir.nodes.values.any? { |node| java_declaration?(node) }
        return true if analyzed_ir.scopes.values.any? { |scope| scope["class_method"] }
        return true if analyzed_ir.data["syntax"]["nodes"].any? { |node| !PRIMITIVE_NODE_KINDS.include?(node["kind"]) }
        return true if analyzed_ir.nodes.values.any? do |node|
          subsequent = node.dig("references", "subsequent").to_i
          node["kind"] == "IfNode" && subsequent >= 0 && analyzed_ir.node(subsequent)["kind"] == "IfNode"
        end
        return true if analyzed_ir.scopes.values.any? do |scope|
          (scope["locals"] || []).any? do |local|
            !%w[int float bool string unknown].include?(local["type"]) && !local["type"].start_with?("object:")
          end
        end

        methods = analyzed_ir.scopes.values.map { |scope| scope["name"] }
        analyzed_ir.nodes.values.any? { |node| boxed_call_required?(analyzed_ir, node, methods) }
      end

      # Check whether a call needs boxed Ruby operations rather than primitive emission.
      def self.boxed_call_required?(analyzed_ir, node, methods)
        return false unless node["kind"] == "CallNode"

        name = node.dig("strings", "name")
        receiver = node.dig("references", "receiver")
        type = receiver && receiver >= 0 ? analyzed_ir.node(receiver).dig("analysis", "type") : nil
        !(%w[puts + - * / % < <= > >= == != new attr_reader attr_writer attr_accessor] + methods).include?(name) ||
          (%w[+ - * / %].include?(name) && node.dig("analysis", "type") == "string") ||
          (%w[/ %].include?(name) && type == "int") ||
          (%w[< <= > >= == !=].include?(name) && !%w[int float].include?(type))
      end
      private_class_method :boxed_call_required?

      # Recognize a compile-time Java directive that selects the Java-ABI lowering path.
      def self.java_declaration?(syntax_node)
        syntax_node["kind"] == "CallNode" && JAVA_CALL_NAMES.include?(syntax_node.dig("strings", "name"))
      end
      private_class_method :java_declaration?

      # Index lexical syntax and initialize compilation-unit state, rejecting native dependencies.
      def initialize(analyzed_ir)
        if analyzed_ir.data.fetch("native_dependencies", {}).values.any?(&:positive?)
          raise UnsupportedNode, "native C/FFI bindings are not implemented by the JVM backend"
        end

        @ir = analyzed_ir
        syntax = analyzed_ir.data.fetch("syntax")
        @nodes = syntax.fetch("nodes").to_h { |node| [node.fetch("id"), node] }
        @root = syntax.fetch("root")
        @units = []
        @unit_ids = {}
        @counter = 0
        @method = nil
      end

      # Compile the boxed runtime and generated program methods into a standalone executable JAR.
      def compile(output)
        # Compile the runtime first so missing javac is a build error, never
        # a partially written executable artifact.
        classes = RuntimeSupport.classes.dup
        root_body = reference(node(@root), "statements")
        root_scope = build_scope(root_body, nil, [])
        register_unit(@root, root_body, -1, root_scope, false)
        compiler = self
        file = BiteScript::FileBuilder.build(@ir.data["source_file"] || "source.rb") do
          compiler.__send__(:emit_program, self, root_scope)
        end
        file.generate { |name, klass| classes[name] = klass.generate }
        JarWriter.write(output, MAIN.tr("/", "."), classes)
      end

      private

      # Fetch a lexical syntax node by its stable node ID.
      def node(id) = @nodes.fetch(id)
      # Return a named child node ID, using -1 for an absent reference.
      def reference(syntax_node, key) = syntax_node.fetch("references", {}).fetch(key, -1)
      # Return a named list of child node IDs, using an empty list when absent.
      def node_list(syntax_node, key) = syntax_node.fetch("arrays", {}).fetch(key, [])
      # Read the optional name field from a lexical syntax node.
      def node_name(syntax_node) = syntax_node.fetch("strings", {})["name"]

      # Create a unique bytecode branch label with the supplied diagnostic prefix.
      def new_label(prefix)
        @counter += 1
        :"#{prefix}_#{@counter}"
      end

      # Emit a static Core runtime call with an explicit JVM result and parameter signature.
      def emit_runtime_call(name, result, *parameter_types)
        @method.invokestatic(CORE, name, [result, *parameter_types])
      end

      # Load the current lexical environment reference onto the operand stack.
      def load_environment = @method.aload(@environment_slot)

      # Allocate a uniquely named JVM local for an intermediate value.
      def allocate_temporary(type = OBJECT)
        @counter += 1
        @method.local("tmp$#{@counter}", type)
      end

      # Return direct child node IDs from nonnegative references and child arrays.
      def children(syntax_node)
        syntax_node.fetch("references", {}).values.reject(&:negative?) + syntax_node.fetch("arrays", {}).values.flatten
      end

      # Collect assigned local names without crossing nested method, class, module, or block scopes.
      def local_names(body)
        names = []
        walk = lambda do |id|
          return if id.negative?

          syntax_node = node(id)
          return if %w[DefNode ClassNode ModuleNode BlockNode].include?(syntax_node["kind"])

          names << node_name(syntax_node) if LOCAL_WRITE_NODES.include?(syntax_node["kind"])
          children(syntax_node).each { |child| walk.call(child) }
        end
        walk.call(body)
        names.compact.uniq
      end

      # Normalize supported parameter syntax to name, binding kind, and default-node tuples.
      # Reject rest, forwarded, and post parameters before bytecode emission.
      def parse_parameters(id)
        return [] if id.negative?

        syntax_node = node(id)
        return parse_parameters(reference(syntax_node, "parameters")) if syntax_node["kind"] == "BlockParametersNode"
        if syntax_node["kind"] == "NumberedParametersNode"
          return (1..syntax_node.dig("integers", "maximum")).map do |i|
            ["_#{i}", :required, -1]
          end
        end

        unsupported!(syntax_node, "parameter layout") unless syntax_node["kind"] == "ParametersNode"
        unsupported_parameters = reference(syntax_node, "rest") >= 0 ||
                                 reference(syntax_node, "keyword_rest") >= 0 ||
                                 !node_list(syntax_node, "posts").empty?
        unsupported!(syntax_node, "rest/forwarded parameters") if unsupported_parameters
        result = node_list(syntax_node, "requireds").map { |child| [node_name(node(child)), :required, -1] }
        result += node_list(syntax_node, "optionals").map do |child|
          [node_name(node(child)), :optional, reference(node(child), "value")]
        end
        result += node_list(syntax_node, "keywords").map do |child|
          parameter_node = node(child)
          kind = parameter_node["kind"] == "RequiredKeywordParameterNode" ? :keyword : :optional_keyword
          [node_name(parameter_node), kind, reference(parameter_node, "value")]
        end
        result << [node_name(node(reference(syntax_node, "block"))), :block, -1] if reference(syntax_node, "block") >= 0
        result
      end

      # Assign lexical slots to parameters and body locals, optionally linking a captured parent scope.
      def build_scope(body, parent, parameters, declared = nil)
        names = declared || local_names(body)
        names = parameters.map(&:first) + names
        LexicalScope.new(names.compact.uniq.each_with_index.to_h, parent)
      end

      # Register a source body once and return its stable generated-function dispatch ID.
      def register_unit(key, body, parameters, scope, block)
        return @unit_ids[key] if @unit_ids.key?(key)

        id = @units.length
        @unit_ids[key] = id
        @units << CompilationUnit.new(id, body, parse_parameters(parameters), scope, block, key)
        id
      end

      # Emit generated function bodies, an ID-based dispatcher, and the Java main entry point.
      # Body emission may register additional block units, so traverse the growing unit list.
      def emit_program(file, root_scope)
        @class_builder = file.public_class(MAIN, java.lang.Object, PROGRAM)
        @class_builder.public_constructor([]) do |method|
          method.aload(0)
          method.invokespecial(java.lang.Object, "<init>", [Java::void])
          method.returnvoid
        end
        index = 0
        while index < @units.length
          emit_unit(@units[index])
          index += 1
        end
        @class_builder.public_method("invoke", [], OBJECT, Java::int, ENVIRONMENT, OBJECT_ARRAY, BLOCK) do |method|
          id = method.local("id", Java::int)
          current = method.local("env", ENVIRONMENT)
          arguments = method.local("args", OBJECT_ARRAY)
          block = method.local("block", BLOCK)
          default = :invalid_function
          labels = @units.map { |unit| :"function_#{unit.id}" }
          method.iload(id)
          method.tableswitch(0, @units.length - 1, default, labels)
          @units.each do |unit|
            method.label(labels[unit.id])
            method.aload(current)
            method.aload(arguments)
            method.aload(block)
            method.invokestatic(@class_builder, "fn$#{unit.id}", [OBJECT, ENVIRONMENT, OBJECT_ARRAY, BLOCK])
            method.areturn
          end
          method.label(default)
          method.aconst_null
          method.areturn
        end
        @class_builder.public_static_method("main", [], Java::void, Java::java.lang.String[]) do |method|
          arguments = method.local("args", Java::java.lang.String[])
          method.new(@class_builder)
          method.dup
          method.invokespecial(@class_builder, "<init>", [Java::void])
          method.aload(arguments)
          method.ldc(root_scope.slots.length)
          method.invokestatic(CORE, "start", [Java::void, PROGRAM, Java::java.lang.String[], Java::int])
          method.returnvoid
        end
      end

      # Emit one boxed function with its environment, argument array, block, and lexical slot bindings.
      def emit_unit(unit)
        @class_builder.public_static_method("fn$#{unit.id}", [], OBJECT, ENVIRONMENT, OBJECT_ARRAY, BLOCK) do |method|
          @method = method
          @environment_slot = method.local("env", ENVIRONMENT)
          @arguments_slot = method.local("args", OBJECT_ARRAY)
          @block_slot = method.local("block", BLOCK)
          @scope = unit.scope
          @unit = unit
          @loops = []
          emit_parameters(unit)
          emit_expression(unit.body)
          method.areturn
        end
      end

      # Return the required and optional keyword parameter tuples for a compilation unit.
      def keyword_parameters(unit)
        unit.parameters.select { |_name, kind, _default| %i[keyword optional_keyword].include?(kind) }
      end

      # Bind positional, keyword, and block arguments into lexical slots.
      # Methods enforce arity; multi-parameter blocks apply Ruby block-argument expansion.
      def emit_parameters(unit)
        emit_arity_check(unit) unless unit.id.zero? || unit.block
        if unit.block && unit.parameters.length > 1
          @method.aload(@arguments_slot)
          emit_runtime_call("blockArgs", OBJECT_ARRAY, OBJECT_ARRAY)
          @method.astore(@arguments_slot)
        end
        position = 0
        unit.parameters.each do |name, kind, default|
          store_variable(name) { emit_parameter_value(unit, name, kind, default, position) }
          position += 1 if %i[required optional].include?(kind)
          @method.pop
        end
      end

      # Emit positional arity and accepted-keyword checks before binding method parameters.
      def emit_arity_check(unit)
        keywords = keyword_parameters(unit).map(&:first)
        @method.aload(@arguments_slot)
        @method.ldc(unit.parameters.count { |_name, kind, _default| kind == :required })
        @method.ldc(unit.parameters.count { |_name, kind, _default| kind == :optional })
        @method.public_send(keywords.empty? ? :iconst_0 : :iconst_1)
        emit_runtime_call("arity", Java::void, OBJECT_ARRAY, Java::int, Java::int, Java::boolean)
        return if keywords.empty?

        @method.aload(@arguments_slot)
        @method.ldc(keywords.join(","))
        emit_runtime_call("checkKeywords", Java::void, OBJECT_ARRAY, STRING)
      end

      # Leave one parameter's supplied or default value on the operand stack.
      def emit_parameter_value(unit, name, kind, default, position)
        case kind
        when :required
          @method.aload(@arguments_slot)
          @method.ldc(position)
          emit_runtime_call("arg", OBJECT, OBJECT_ARRAY, Java::int)
        when :optional
          emit_optional_argument(unit, position, default)
        when :keyword
          @method.aload(@arguments_slot)
          @method.ldc(name)
          emit_runtime_call("keyword", OBJECT, OBJECT_ARRAY, STRING)
        when :optional_keyword
          emit_optional_keyword(name, default)
        when :block
          @method.aload(@block_slot)
        else
          unsupported!(node(unit.node_id), "optional keyword parameters")
        end
      end

      # Load a positional argument if present; otherwise evaluate its default expression.
      def emit_optional_argument(unit, position, default)
        missing = new_label("optional_missing")
        done = new_label("optional_done")
        @method.aload(@arguments_slot)
        if keyword_parameters(unit).empty?
          @method.arraylength
        else
          emit_runtime_call("positionalSize", Java::int, OBJECT_ARRAY)
        end
        @method.ldc(position)
        @method.if_icmple(missing)
        @method.aload(@arguments_slot)
        @method.ldc(position)
        @method.aaload
        @method.goto(done)
        @method.label(missing)
        emit_expression(default)
        @method.label(done)
      end

      # Load a supplied keyword value, evaluating its default only when the keyword is absent.
      def emit_optional_keyword(name, default)
        missing = new_label("keyword_missing")
        done = new_label("keyword_done")
        @method.aload(@arguments_slot)
        @method.ldc(name)
        emit_runtime_call("hasKeyword", Java::boolean, OBJECT_ARRAY, STRING)
        @method.ifeq(missing)
        @method.aload(@arguments_slot)
        @method.ldc(name)
        emit_runtime_call("keyword", OBJECT, OBJECT_ARRAY, STRING)
        @method.goto(done)
        @method.label(missing)
        emit_expression(default)
        @method.label(done)
      end

      # Emit a lexical-cell write using the yielded value, leaving the assigned value on the stack.
      def store_variable(variable)
        depth, slot = @scope.resolve_binding(variable)
        load_environment
        @method.ldc(depth)
        @method.ldc(slot)
        yield
        emit_runtime_call("set", OBJECT, ENVIRONMENT, Java::int, Java::int, OBJECT)
      end

      # Load a local from the current environment or a captured ancestor's lexical slot.
      def read_variable(variable)
        depth, slot = @scope.resolve_binding(variable)
        load_environment
        @method.ldc(depth)
        @method.ldc(slot)
        emit_runtime_call("get", OBJECT, ENVIRONMENT, Java::int, Java::int)
      end

      # Evaluate node IDs in order and store their boxed values in a new Java Object array.
      def emit_object_array(ids)
        @method.ldc(ids.length)
        @method.anewarray(OBJECT)
        ids.each_with_index do |id, index|
          @method.dup
          @method.ldc(index)
          emit_expression(id)
          @method.aastore
        end
      end

      # Return a call or jump node's argument IDs, treating an absent argument list as empty.
      def argument_ids(syntax_node)
        id = reference(syntax_node, "arguments")
        id.negative? ? [] : node_list(node(id), "arguments")
      end

      # Register a block body and create a runtime closure capturing the current environment.
      def emit_block(id)
        if id.negative?
          @method.aconst_null
          return
        end
        syntax_node = node(id)
        unsupported!(syntax_node, "block forwarding") unless syntax_node["kind"] == "BlockNode"
        parameters = parse_parameters(reference(syntax_node, "parameters"))
        names = syntax_node.fetch("strings", {}).fetch("locals", "").split(",")
        scope = build_scope(reference(syntax_node, "body"), @scope, parameters, names)
        unit = register_unit(id, reference(syntax_node, "body"), reference(syntax_node, "parameters"), scope, true)
        load_environment
        @method.ldc(unit)
        @method.ldc(scope.slots.length)
        emit_runtime_call("block", BLOCK, ENVIRONMENT, Java::int, Java::int)
      end

      # Emit a lexical syntax node as a boxed value, using null for nil or absent bodies.
      # Collection, object, and library operations call Core; nested bodies remain compiled methods.
      def emit_expression(id)
        if id.negative?
          @method.aconst_null
          return
        end
        syntax_node = node(id)
        line = syntax_node.dig("integers", "node_line")
        @method.line(line) if line&.positive?
        case syntax_node["kind"]
        when "StatementsNode"
          body = node_list(syntax_node, "body")
          body.each_with_index do |child, i|
            emit_expression(child)
            @method.pop if i < body.length - 1
          end
          @method.aconst_null if body.empty?
        when "IntegerNode"
          if syntax_node.dig("strings", "bigval")
            @method.ldc(syntax_node.dig("strings", "bigval"))
            emit_runtime_call("integerLiteral", OBJECT, STRING)
          elsif syntax_node["integers"].key?("value")
            @method.ldc_long(syntax_node["integers"]["value"])
            emit_runtime_call("number", OBJECT, Java::long)
          else
            @method.ldc(syntax_node["content"])
            emit_runtime_call("integerLiteral", OBJECT, STRING)
          end
        when "FloatNode"
          @method.ldc_double(Float(syntax_node.fetch("content")))
          emit_runtime_call("real", OBJECT, Java::double)
        when "StringNode"
          @method.ldc(syntax_node.dig("strings", "content"))

          @method.public_send(syntax_node.dig("integers", "fzl") == 1 ? :iconst_1 : :iconst_0)
          emit_runtime_call("string", OBJECT, STRING, Java::boolean)
        when "SymbolNode"
          @method.ldc(syntax_node.dig("strings", "value"))
          emit_runtime_call("symbol", OBJECT, STRING)
        when "TrueNode", "FalseNode"
          @method.public_send(syntax_node["kind"] == "TrueNode" ? :iconst_1 : :iconst_0)
          emit_runtime_call("bool", OBJECT, Java::boolean)
        when "NilNode" then @method.aconst_null
        when "SelfNode" then load_environment
                             emit_runtime_call("self", OBJECT, ENVIRONMENT)
        when "LocalVariableReadNode" then read_variable(node_name(syntax_node))
        when "LocalVariableWriteNode" then store_variable(node_name(syntax_node)) do
          emit_expression(reference(syntax_node, "value"))
        end
        when "LocalVariableOperatorWriteNode"
          store_variable(node_name(syntax_node)) do
            @method.ldc(syntax_node.dig("strings", "binary_operator"))

            read_variable(node_name(syntax_node))
            emit_expression(reference(syntax_node, "value"))
            emit_runtime_call("binary", OBJECT, STRING, OBJECT, OBJECT)
          end
        when "InstanceVariableReadNode", "GlobalVariableReadNode", "ConstantReadNode"
          load_environment
          @method.ldc(node_name(syntax_node))
          emit_runtime_call(
            { "InstanceVariableReadNode" => "ivar", "GlobalVariableReadNode" => "global",
              "ConstantReadNode" => "constant" }.fetch(syntax_node["kind"]), OBJECT, ENVIRONMENT, STRING
          )
        when "InstanceVariableWriteNode", "GlobalVariableWriteNode", "ConstantWriteNode"
          load_environment
          @method.ldc(node_name(syntax_node))
          emit_expression(reference(syntax_node, "value"))
          emit_runtime_call(
            { "InstanceVariableWriteNode" => "ivarSet", "GlobalVariableWriteNode" => "globalSet",
              "ConstantWriteNode" => "constantSet" }.fetch(syntax_node["kind"]), OBJECT, ENVIRONMENT, STRING, OBJECT
          )
        when "ConstantPathNode"
          emit_expression(reference(syntax_node, "parent"))
          @method.ldc(node_name(syntax_node))
          emit_runtime_call("constantAt", OBJECT, OBJECT, STRING)
        when "ArrayNode"
          emit_object_array(node_list(syntax_node, "elements"))
          emit_runtime_call("array", OBJECT, OBJECT_ARRAY)
        when "HashNode", "KeywordHashNode"
          pairs = node_list(syntax_node, "elements").flat_map do |pair|
            pair = node(pair)
            unsupported!(pair, "hash splat") unless pair["kind"] == "AssocNode"
            [reference(pair, "key"), reference(pair, "value")]
          end
          emit_object_array(pairs)

          @method.public_send(syntax_node["kind"] == "KeywordHashNode" ? :iconst_1 : :iconst_0)
          emit_runtime_call("dict", OBJECT, OBJECT_ARRAY, Java::boolean)
        when "InterpolatedStringNode"
          emit_object_array(node_list(syntax_node, "parts"))
          emit_runtime_call("interpolate", OBJECT, OBJECT_ARRAY)
        when "EmbeddedStatementsNode", "ParenthesesNode"
          body = reference(syntax_node, "statements")
          body = reference(syntax_node, "body") if body.negative?
          emit_expression(body)
        when "IfNode", "UnlessNode" then emit_if(syntax_node)
        when "ElseNode" then emit_expression(reference(syntax_node, "statements"))
        when "AndNode", "OrNode" then emit_logical(syntax_node)
        when "WhileNode", "UntilNode" then emit_loop(syntax_node)
        when "ReturnNode", "BreakNode", "NextNode" then emit_jump(syntax_node)
        when "CallNode" then emit_call(syntax_node)
        when "DefNode" then emit_definition(syntax_node)
        when "ClassNode", "ModuleNode" then emit_class(syntax_node)
        when "RangeNode"
          emit_expression(reference(syntax_node, "left"))

          emit_expression(reference(syntax_node, "right"))
          @method.public_send(syntax_node.dig("integers", "flags").to_i.nobits?(4) ? :iconst_0 : :iconst_1)
          emit_runtime_call("range", OBJECT, OBJECT, OBJECT, Java::boolean)
        when "YieldNode"
          load_environment
          emit_object_array(argument_ids(syntax_node))
          emit_runtime_call("yield", OBJECT, ENVIRONMENT, OBJECT_ARRAY)
        when "MultiWriteNode" then emit_multi_write(syntax_node)
        when "CaseNode" then emit_case(syntax_node)
        else unsupported!(syntax_node, syntax_node["kind"])
        end
      end

      # Emit a boxed conditional using Ruby truthiness and retain the selected branch's value.
      def emit_if(syntax_node)
        alternative = new_label("else")
        done = new_label("if_done")
        emit_expression(reference(syntax_node, "predicate"))
        emit_runtime_call("truth", Java::boolean, OBJECT)
        @method.public_send(syntax_node["kind"] == "UnlessNode" ? :ifne : :ifeq, alternative)
        emit_expression(reference(syntax_node, "statements"))
        @method.goto(done)
        @method.label(alternative)
        emit_expression(reference(syntax_node, syntax_node["kind"] == "UnlessNode" ? "else_clause" : "subsequent"))
        @method.label(done)
      end

      # Emit short-circuit and/or while retaining the selected operand rather than a boolean.
      def emit_logical(syntax_node)
        done = new_label("logical_done")
        emit_expression(reference(syntax_node, "left"))
        @method.dup
        emit_runtime_call("truth", Java::boolean, OBJECT)
        @method.public_send(syntax_node["kind"] == "AndNode" ? :ifeq : :ifne, done)
        @method.pop
        emit_expression(reference(syntax_node, "right"))
        @method.label(done)
      end

      # Emit while/until with local jump targets and a result slot for break values.
      def emit_loop(syntax_node)
        head = new_label("loop")
        done = new_label("loop_done")
        result = allocate_temporary
        @method.aconst_null
        @method.astore(result)
        @loops << [head, done, result]
        @method.label(head)
        emit_expression(reference(syntax_node, "predicate"))
        emit_runtime_call("truth", Java::boolean, OBJECT)
        @method.public_send(syntax_node["kind"] == "UntilNode" ? :ifne : :ifeq, done)
        emit_expression(reference(syntax_node, "statements"))
        @method.pop
        @method.goto(head)
        @method.label(done)
        @method.aload(result)
        @loops.pop
      end

      # Branch directly for break/next inside the current loop.
      # Use targeted runtime control flow for returns and jumps across generated method boundaries.
      def emit_jump(syntax_node)
        kind = syntax_node["kind"].delete_suffix("Node").downcase
        arguments = argument_ids(syntax_node)
        if !@loops.empty? && kind != "return"
          head, done, result = @loops.last
          if kind == "break"
            arguments.empty? ? @method.aconst_null : emit_expression(arguments.first)
            @method.astore(result)
            @method.goto(done)
          else
            @method.goto(head)
          end
          @method.aconst_null
        else
          load_environment
          @method.ldc(kind)
          if arguments.empty?
            @method.aconst_null
          else
            (if arguments.length == 1
               emit_expression(arguments.first)
             else
               (emit_object_array(arguments)

                emit_runtime_call("array", OBJECT, OBJECT_ARRAY))
             end)
          end
          emit_runtime_call("jump", OBJECT, ENVIRONMENT, STRING, OBJECT)
        end
      end

      # Emit static define_method closures, specialized binary operations, or runtime dispatch.
      # Preserve the receiver, argument order, current environment, and optional captured block.
      def emit_call(syntax_node)
        arguments = argument_ids(syntax_node)
        if reference(syntax_node, "receiver").negative? && node_name(syntax_node) == "define_method"
          unless arguments.length == 1 && node(arguments[0])["kind"] == "SymbolNode" && reference(
            syntax_node, "block"
          ) >= 0
            unsupported!(syntax_node,
                         "dynamic define_method")
          end
          block = node(reference(syntax_node, "block"))
          parameters = parse_parameters(reference(block, "parameters"))
          scope = build_scope(reference(block, "body"), @scope, parameters,
                              block.dig("strings", "locals").to_s.split(","))
          unit = register_unit(block["id"], reference(block, "body"), reference(block, "parameters"), scope, false)
          load_environment
          @method.ldc(node(arguments[0]).dig("strings", "value"))
          @method.ldc(unit)
          @method.ldc(scope.slots.length)
          emit_runtime_call("defineClosure", OBJECT, ENVIRONMENT, STRING, Java::int, Java::int)
          return
        end
        receiver = reference(syntax_node, "receiver")
        if receiver >= 0 && arguments.length == 1 && BINARY_OPERATORS.include?(node_name(syntax_node)) &&
           reference(syntax_node, "block").negative?
          fast = { "+" => "add", "-" => "sub", "*" => "mul", "/" => "div", "%" => "mod" }[node_name(syntax_node)]
          @method.ldc(node_name(syntax_node)) unless fast
          emit_expression(receiver)
          emit_expression(arguments.first)
          if fast
            emit_runtime_call(fast, OBJECT, OBJECT,
                              OBJECT)
          else
            emit_runtime_call("binary", OBJECT, STRING, OBJECT, OBJECT)
          end
          return
        end
        load_environment
        emit_expression(receiver) if receiver >= 0
        @method.ldc(node_name(syntax_node))
        emit_object_array(arguments)
        emit_block(reference(syntax_node, "block"))
        if receiver >= 0
          emit_runtime_call("call", OBJECT, ENVIRONMENT, OBJECT, STRING, OBJECT_ARRAY,
                            BLOCK)
        else
          emit_runtime_call("bare", OBJECT, ENVIRONMENT, STRING, OBJECT_ARRAY, BLOCK)
        end
      end

      # Register a method body and install it in the runtime's instance or singleton method table.
      def emit_definition(syntax_node)
        parameters = parse_parameters(reference(syntax_node, "parameters"))
        scope = build_scope(reference(syntax_node, "body"), nil, parameters)
        unit = register_unit(syntax_node["id"], reference(syntax_node, "body"), reference(syntax_node, "parameters"),
                             scope, false)
        load_environment
        @method.ldc(node_name(syntax_node))
        @method.ldc(unit)
        @method.ldc(scope.slots.length)
        @method.public_send(reference(syntax_node, "receiver") >= 0 ? :iconst_1 : :iconst_0)
        emit_runtime_call("define", OBJECT, ENVIRONMENT, STRING, Java::int, Java::int, Java::boolean)
      end

      # Enter a runtime class/module environment, emit its body, then restore the enclosing emission scope.
      def emit_class(syntax_node)
        constant = node(reference(syntax_node, "constant_path"))
        unsupported!(syntax_node, "qualified class/module declarations") unless constant["kind"] == "ConstantReadNode"
        scope = build_scope(reference(syntax_node, "body"), nil, [])
        old_env = @environment_slot
        old_scope = @scope
        current = allocate_temporary(ENVIRONMENT)
        load_environment
        @method.ldc(node_name(constant))
        emit_expression(reference(syntax_node, "superclass"))
        @method.public_send(syntax_node["kind"] == "ModuleNode" ? :iconst_1 : :iconst_0)
        @method.ldc(scope.slots.length)
        emit_runtime_call("classEnv", ENVIRONMENT, ENVIRONMENT, STRING, OBJECT, Java::boolean, Java::int)
        @method.astore(current)
        @environment_slot = current
        @scope = scope
        emit_expression(reference(syntax_node, "body"))
        @environment_slot = old_env
        @scope = old_scope
      end

      # Evaluate an assignment value once and distribute its indexed elements to supported targets.
      def emit_multi_write(syntax_node)
        value = allocate_temporary
        emit_expression(reference(syntax_node, "value"))
        @method.astore(value)
        unsupported!(syntax_node, "destructuring with rest/post targets") if reference(syntax_node,
                                                                                       "rest") >= 0 || !node_list(
                                                                                         syntax_node, "rights"
                                                                                       ).empty?
        node_list(syntax_node, "lefts").each_with_index do |id, index|
          target = node(id)
          load = lambda {
            @method.aload(value)
            @method.ldc(index)
            emit_runtime_call("element", OBJECT, OBJECT, Java::int)
          }
          if target["kind"] == "LocalVariableTargetNode"
            store_variable(node_name(target), &load)
          elsif target["kind"] == "InstanceVariableTargetNode"
            load_environment
            @method.ldc(node_name(target))
            load.call
            emit_runtime_call("ivarSet", OBJECT, ENVIRONMENT, STRING, OBJECT)
          else
            unsupported!(target, "destructuring target")
          end
          @method.pop
        end
        @method.aload(value)
      end

      # Evaluate the case predicate once and branch using Ruby-style case equality tests.
      def emit_case(syntax_node)
        predicate = allocate_temporary
        emit_expression(reference(syntax_node, "predicate"))
        @method.astore(predicate)
        done = new_label("case_done")
        node_list(syntax_node, "conditions").each do |id|
          condition = node(id)
          matched = new_label("case_match")
          following = new_label("case_next")
          node_list(condition, "conditions").each do |pattern|
            emit_expression(pattern)

            @method.aload(predicate)
            emit_runtime_call("isCase", Java::boolean, OBJECT, OBJECT)
            @method.ifne(matched)
          end
          @method.goto(following)
          @method.label(matched)
          emit_expression(reference(condition, "statements"))
          @method.goto(done)
          @method.label(following)
        end
        emit_expression(reference(syntax_node, "else_clause"))
        @method.label(done)
      end

      # Raise a boxed-lowering error containing the source location, operation, and syntax node.
      def unsupported!(syntax_node, operation)
        location = "#{@ir.data["source_file"]}:#{syntax_node.dig("integers", "node_line") || 0}"
        description = "#{syntax_node["kind"]} node #{syntax_node["id"]}"
        raise UnsupportedNode,
              "#{location}: JVM core lowering does not support #{operation} (#{description})"
      end
    end
  end
end
