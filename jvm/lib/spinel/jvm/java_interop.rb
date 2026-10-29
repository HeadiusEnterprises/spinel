# frozen_string_literal: true

module Spinel
  module JVM
    # Resolves Java signatures and emits direct calls against the classpath.
    module JavaInterop
      private

      # Create the compilation class loader, then collect and validate Java declarations.
      # Resolve contracts and call-site types before bytecode emission.
      def configure_java_interop
        urls = @classpath.map do |path|
          raise UnsupportedNode, "Java classpath entry does not exist: #{path}" unless File.exist?(path)

          java.io.File.new(path).to_uri.to_url
        end
        parent = java.lang.Thread.current_thread.context_class_loader
        @java_loader = if urls.empty?
                         parent
                       else
                         java.net.URLClassLoader.new(urls.to_java(java.net.URL), parent)
                       end
        collect_java_imports
        collect_java_type_declarations
        collect_java_signatures
        configure_java_contracts
        resolve_java_calls
        validate_java_exports
      end

      # Resolve java_import class names and reject unsupported renaming or conflicting simple names.
      def collect_java_imports
        @ir.nodes.each_value do |node|
          next unless java_import_call?(node)

          unsupported!(node, "java_import block renaming") if node.dig("references", "block") != -1
          arguments = call_arguments(node)
          unsupported!(node, "java_import without classes") if arguments.empty?
          arguments.each do |argument|
            binary_name = java_import_name(@ir.node(argument))
            java_class = load_java_class(binary_name, node)
            simple_name = java_class.simple_name
            if @java_imports.key?(simple_name) && @java_imports[simple_name].name != binary_name
              unsupported!(node, "conflicting Java import #{simple_name}")
            end
            @java_imports[simple_name] = java_class
          end
        end
      end

      # Associate each literal java_signature with the immediately following instance-method definition.
      def collect_java_signatures
        @ir.nodes.each_value do |statements|
          next unless statements["kind"] == "StatementsNode"

          pending = nil
          statements.fetch("arrays").fetch("body", []).each do |id|
            node = @ir.node(id)
            if java_signature_call?(node)
              unsupported!(node, "consecutive java_signature directives") if pending
              pending = parse_java_signature(node)
            elsif node["kind"] == "DefNode" && pending
              scopes = @all_instance_scopes.select { |entry| entry["definition"] == node["id"] }
              unsupported!(node, "java_signature outside an instance method") if scopes.empty?
              scopes.each { |scope| install_java_signature(scope, pending, node) }
              pending = nil
            elsif pending && !%w[DefNode].include?(node["kind"])
              unsupported!(node, "java_signature not immediately followed by a method")
            end
          end
          unsupported!(statements, "java_signature without a following method") if pending
        end
      end

      # Parse JRuby's Java declaration syntax into Java and Spinel signature metadata.
      # Preserve visibility and throws types while rejecting unsupported modifiers.
      def parse_java_signature(node, abstract: false)
        arguments = call_arguments(node)
        unsupported!(node, "java_signature without one literal string") unless arguments.length == 1
        literal = @ir.node(arguments.first)
        require_kind!(literal, "StringNode")
        source = literal.fetch("strings").fetch("content")
        parsed = JRuby::JavaSignature.parse(source)
        ast = parsed.instance_variable_get(:@ast)
        parameters = ast.parameters.map { |parameter| java_signature_type(parameter.type.to_s, node) }
        return_type = java_signature_type(ast.return_type.to_s, node, allow_void: true)
        modifiers = ast.modifiers.map(&:to_s)
        unsupported!(node, "static java_signature") if modifiers.include?("static")
        visibility = (%w[public protected private] & modifiers).first || "public"
        unsupported_modifiers = modifiers.reject do |modifier|
          (%w[public protected private] + (abstract ? ["abstract"] : [])).include?(modifier)
        end
        unsupported!(node, "java_signature modifiers #{unsupported_modifiers.join(", ")}") unless
          unsupported_modifiers.empty?
        spinel_parameters = parameters.map { |type| java_spinel_type(type, node) }
        spinel_return = java_spinel_type(return_type, node, allow_void: true)
        {
          name: ast.name.to_s,
          visibility: visibility.to_sym,
          exceptions: ast.throws.map { |type| java_signature_type(type.to_s, node) },
          parameter_types: parameters,
          return_type: return_type,
          spinel_parameters: spinel_parameters,
          spinel_return: spinel_return,
          source: source
        }
      rescue org.jruby.parser.ParserSyntaxException => error
        unsupported!(node, "invalid java_signature: #{error.message}")
      end

      # Propagate Java types through local assignments, reads, and resolved calls to a fixed point.
      # Stop when metadata stabilizes, with a node-count bound on inference passes.
      def resolve_java_calls
        java_enabled = @ir.data.fetch("features", []).include?("java") || !@java_imports.empty?
        return unless java_enabled

        (@ir.nodes.length + 1).times do
          changed = false
          @ir.nodes.each_value do |node|
            case node["kind"]
            when "LocalVariableWriteNode"
              value_type = node_type(@ir.node(node.dig("references", "value")))
              next if %w[unknown poly].include?(value_type)

              key = [node.dig("analysis", "scope"), node.dig("strings", "name")]
              merged = merge_java_types(@java_local_types[key], value_type, node)
              unless @java_local_types[key] == merged
                @java_local_types[key] = merged
                changed = true
              end
            when "LocalVariableReadNode"
              key = [node.dig("analysis", "scope"), node.dig("strings", "name")]
              type = @java_local_types[key]
              if type && @java_node_types[node["id"]] != type
                @java_node_types[node["id"]] = type
                changed = true
              end
            when "CallNode"
              next if java_compile_time_call?(node)

              resolved = resolve_java_call(node)
              if resolved && @java_calls[node["id"]] != resolved
                @java_calls[node["id"]] = resolved
                @java_node_types[node["id"]] = resolved.fetch(:spinel_return)
                changed = true
              end
            end
          end
          break unless changed
        end
      end

      # Resolve generated, exact, constructor, static, or inherited Java calls when the receiver permits it.
      def resolve_java_call(node)
        special = resolve_generated_java_call(node)
        return special if special
        return resolve_java_send(node) if node.dig("strings", "name") == "java_send"

        receiver_id = node.dig("references", "receiver")
        if receiver_id.nil? || receiver_id.negative?
          class_id = @ir.scope(node.dig("analysis", "scope"))["class"]
          parent = external_java_parent(class_id)
          return nil unless parent && !find_instance_scope(class_id, node.dig("strings", "name"),
                                                           call_arguments(node).length)

          return resolve_java_method(node, parent, static: false)
        end
        receiver = @ir.node(receiver_id)
        java_class = java_class_value(receiver)
        if java_class
          return resolve_java_constructor(node, java_class) if node.dig("strings", "name") == "new"

          return resolve_java_method(node, java_class, static: true)
        end
        receiver_type = node_type(receiver)
        if object_type?(receiver_type)
          class_id = object_class(receiver_type)
          return nil if find_instance_scope(class_id, node.dig("strings", "name"), call_arguments(node).length)

          parent = external_java_parent(class_id)
          return resolve_java_method(node, parent, static: false) if parent
        end
        return nil unless java_reference_type?(receiver_type)

        resolve_java_method(node, load_java_class_by_name(receiver_type.delete_prefix("java:"), node), static: false)
      end

      # Select a compatible public Java constructor and record its arguments and inferred result type.
      def resolve_java_constructor(node, java_class)
        arguments = call_arguments(node)
        ranked = rank_java_executables(java_class.constructors.to_a, arguments)
        constructor = select_java_executable(node, "constructor #{java_class.name}", ranked)
        return nil unless constructor

        {
          kind: :constructor, constructor: constructor,
          arguments: arguments, spinel_return: java_spinel_type(java_class, node)
        }
      end

      # Select a public Java method of the requested static/instance form.
      # Deduplicate bridge/synthetic alternatives before ranking overload conversions.
      def resolve_java_method(node, java_class, static:)
        name = node.fetch("strings").fetch("name")
        arguments = call_arguments(node)
        candidates = java_class.java_send(:getMethods).select do |method|
          method.name == name && java.lang.reflect.Modifier.static?(method.modifiers) == static &&
            method.parameter_types.length == arguments.length
        end
        candidates = candidates.group_by { |method| method.parameter_types.map(&:name) }.values.map do |same_parameters|
          same_parameters.min_by { |method| [method.bridge? ? 1 : 0, method.synthetic? ? 1 : 0, method.to_s] }
        end
        method = select_java_executable(
          node, "Java call #{java_class.name}.#{name}", rank_java_executables(candidates, arguments)
        )
        return nil unless method

        {
          kind: static ? :static : :instance, method: method,
          receiver: node.dig("references", "receiver"), arguments: arguments,
          spinel_return: java_spinel_type(method.return_type, node, allow_void: true)
        }
      end

      # Resolve JRuby-style java_send using a literal method name and exact parameter types.
      # Omitting the type array requests a zero-argument method; actual values must remain compatible.
      def resolve_java_send(node)
        receiver_id = node.dig("references", "receiver")
        return nil if receiver_id.nil? || receiver_id.negative?

        arguments = call_arguments(node)
        unsupported!(node, "java_send without a method name") if arguments.empty?
        name_node = @ir.node(arguments.first)
        unless %w[SymbolNode StringNode].include?(name_node["kind"])
          unsupported!(node, "java_send method name that is not a symbol or string literal")
        end
        name = name_node.dig("strings", name_node["kind"] == "SymbolNode" ? "value" : "content")
        if arguments.length == 1
          parameter_types = []
          actual_arguments = []
        else
          types_node = @ir.node(arguments[1])
          require_kind!(types_node, "ArrayNode")
          parameter_types = types_node.fetch("arrays").fetch("elements").map do |id|
            java_type_expression(@ir.node(id), node)
          end
          actual_arguments = arguments.drop(2)
        end
        unsupported!(node, "java_send argument count does not match parameter types") unless
          parameter_types.length == actual_arguments.length

        receiver = @ir.node(receiver_id)
        java_class = java_class_value(receiver)
        static = !java_class.nil?
        unless java_class
          receiver_type = node_type(receiver)
          return nil unless java_reference_type?(receiver_type)

          java_class = load_java_class_by_name(receiver_type.delete_prefix("java:"), node)
        end
        candidates = java_class.java_send(:getMethods).select do |method|
          method.name == name && java.lang.reflect.Modifier.static?(method.modifiers) == static &&
            method.parameter_types.map(&:name) == parameter_types.map(&:name)
        end
        if candidates.empty?
          unsupported!(node,
                       "Java method #{java_class.name}.#{name}(#{parameter_types.map(&:name).join(", ")})")
        end
        method = candidates.min_by(&:to_s)
        actual_arguments.zip(parameter_types).each do |argument, parameter|
          next if java_parameter_score(node_type(@ir.node(argument)), parameter)

          unsupported!(node, "java_send argument incompatible with #{parameter.name}")
        end
        {
          kind: static ? :static : :instance, method: method,
          receiver: receiver_id, arguments: actual_arguments,
          spinel_return: java_spinel_type(method.return_type, node, allow_void: true), exact: true
        }
      end

      # Recognize an unqualified java_import declaration in the analyzed node table.
      def java_import_call?(node)
        node["kind"] == "CallNode" && node.dig("strings", "name") == "java_import" &&
          node.dig("references", "receiver") == -1
      end

      # Recognize an unqualified java_signature declaration in the analyzed node table.
      def java_signature_call?(node)
        node["kind"] == "CallNode" && node.dig("strings", "name") == "java_signature" &&
          node.dig("references", "receiver") == -1
      end

      # Read a literal binary-name string or reconstruct the Java class expression used in an import.
      def java_import_name(node)
        return node.dig("strings", "content") if node["kind"] == "StringNode"

        name = java_expression_name(node)
        unsupported!(node, "java_import argument that is not a Java class or binary-name string") unless name
        name
      end

      # Reconstruct dotted Java names from constants and argument-free qualified calls.
      def java_expression_name(node)
        case node["kind"]
        when "ConstantReadNode"
          node.dig("strings", "name")
        when "CallNode"
          return nil unless call_arguments(node).empty?

          receiver_id = node.dig("references", "receiver")
          prefix = receiver_id && receiver_id >= 0 ? java_expression_name(@ir.node(receiver_id)) : nil
          prefix ? "#{prefix}.#{node.dig("strings", "name")}" : node.dig("strings", "name")
        when "ConstantPathNode"
          parent = java_expression_name(@ir.node(node.dig("references", "parent")))
          parent && "#{parent}.#{node.dig("strings", "name")}"
        end
      end

      # Resolve a class-valued expression through imports, implicit java.lang names, or qualified lookup.
      def java_class_value(node)
        if node["kind"] == "ConstantReadNode"
          name = node.dig("strings", "name")
          return @java_imports[name] || try_java_lang(name)
        end
        name = java_expression_name(node)
        return nil unless name&.include?(".")

        try_load_java_class(name)
      end

      # Resolve a java_send parameter type expression to a primitive, imported, or declared Java type.
      def java_type_expression(node, context)
        name = java_expression_name(node)
        unsupported!(context, "java_send parameter type") unless name
        return primitive_java_class(name.delete_prefix("Java.")) if name.start_with?("Java.")
        return @java_imports.fetch(name) if @java_imports.key?(name)

        java_signature_type(name, context)
      end

      # Load a class without initialization, reporting missing classpath entries against the source node.
      def load_java_class(binary_name, node)
        java.lang.Class.for_name(binary_name, false, @java_loader)
      rescue java.lang.ClassNotFoundException
        unsupported!(node, "Java class #{binary_name} not found on the classpath")
      end

      # Load a class without initialization and identify the resolution context if lookup fails.
      def load_java_class_by_name(binary_name, context)
        java.lang.Class.for_name(binary_name, false, @java_loader)
      rescue java.lang.ClassNotFoundException
        raise UnsupportedNode, "Java class #{binary_name} not found while resolving #{context}"
      end

      # Attempt class lookup without initialization, returning nil when the class is absent.
      def try_load_java_class(binary_name)
        java.lang.Class.for_name(binary_name, false, @java_loader)
      rescue java.lang.ClassNotFoundException
        nil
      end

      # Attempt implicit java.lang lookup for a simple class name without initializing the class.
      def try_java_lang(simple_name)
        java.lang.Class.for_name("java.lang.#{simple_name}", false, @java_loader)
      rescue java.lang.ClassNotFoundException
        nil
      end

      # Score a supported Spinel-to-Java conversion; lower scores are preferred and nil means incompatible.
      # Distinguish primitive narrowing, reference assignability, generated types, and nil references.
      def java_parameter_score(spinel_type, java_class)
        if java_class.is_a?(JavaTypes::DeclaredType)
          return 20 if spinel_type == "nil"

          return object_type?(spinel_type) && generated_subtype?(object_class(spinel_type),
                                                                 java_class.class_id) ? 0 : nil
        end
        java_name = java_class.name
        case spinel_type
        when "int"
          { "long" => 0, "int" => 1, "short" => 2, "byte" => 2, "char" => 2 }[java_name]
        when "float"
          { "double" => 0, "float" => 1 }[java_name]
        when "bool"
          java_name == "boolean" ? 0 : nil
        when "string"
          return nil if java_class.primitive?

          source = java.lang.String.java_class
          if java_class == source
            0
          else
            (java_class.assignable_from?(source) ? 4 : nil)
          end
        when "nil"
          java_class.primitive? ? nil : 20
        else
          if object_type?(spinel_type) && !java_class.primitive?
            return generated_java_assignable?(object_class(spinel_type), java_class) ? 4 : nil
          end
          return nil unless java_reference_type?(spinel_type) && !java_class.primitive?

          source = load_java_class_by_name(spinel_type.delete_prefix("java:"), spinel_type)
          if java_class == source
            0
          else
            (java_class.assignable_from?(source) ? 4 : nil)
          end
        end
      end

      # Pair compatible fixed-arity Java methods/constructors with total conversion scores and signatures.
      def rank_java_executables(candidates, arguments)
        candidates.filter_map do |executable|
          next unless executable.parameter_types.length == arguments.length

          scores = arguments.zip(executable.parameter_types).map do |argument, parameter|
            java_parameter_score(node_type(@ir.node(argument)), parameter)
          end
          next if scores.any?(&:nil?)

          [scores.sum, executable.to_s, executable]
        end
      end

      # Merge compatible Java reference flows using assignability or a shared superclass; reject other conflicts.
      def merge_java_types(existing, incoming, node)
        return incoming unless existing
        return existing if existing == incoming

        unless java_reference_type?(existing) && java_reference_type?(incoming)
          unsupported!(node, "incompatible Java-flow types #{existing} and #{incoming}")
        end
        left = load_java_class_by_name(existing.delete_prefix("java:"), node)
        right = load_java_class_by_name(incoming.delete_prefix("java:"), node)
        return existing if left.assignable_from?(right)
        return incoming if right.assignable_from?(left)

        current = left.superclass
        current = current.superclass while current && !current.assignable_from?(right)
        "java:#{(current || java.lang.Object.java_class).name}"
      end

      # Select the lowest-scoring overload, breaking ties by reference-parameter specificity.
      # Reject unresolved ties with candidate signatures and an exact java_send diagnostic.
      def select_java_executable(node, description, ranked)
        return nil if ranked.empty?

        ranked.sort_by! { |score, signature, _executable| [score, signature] }
        tied = ranked.take_while { |entry| entry[0] == ranked[0][0] }
        if tied.length > 1
          most_specific = tied.select do |candidate|
            tied.all? do |other|
              candidate.equal?(other) || more_specific_parameters?(
                candidate[2].parameter_types, other[2].parameter_types
              )
            end
          end
          return most_specific.first[2] if most_specific.length == 1

          signatures = tied.map { |entry| entry[1] }
          unsupported!(node, "ambiguous #{description}: #{signatures.join(" or ")}; use java_send for an exact method")
        end
        ranked.first[2]
      end

      # Check whether every candidate parameter is identical to or a reference subtype of its counterpart.
      def more_specific_parameters?(candidate, other)
        candidate.zip(other).all? do |left, right|
          left == right || (!left.primitive? && !right.primitive? && right.assignable_from?(left))
        end
      end

      # Map a Java ABI type to its logical Spinel type tag, optionally accepting a void result.
      def java_spinel_type(java_class, node, allow_void: false)
        return "object:#{java_class.class_id}" if java_class.is_a?(JavaTypes::DeclaredType)

        name = java_class.name
        return "nil" if allow_void && name == "void"
        return "int" if %w[long int short byte char].include?(name)
        return "float" if %w[double float].include?(name)
        return "bool" if name == "boolean"
        return "string" if name == "java.lang.String"
        return "java:#{name}" unless java_class.primitive?

        unsupported!(node, "Java type #{name}")
      end

      # Resolve signature type names, including generated types, imports, primitives, and reflected arrays.
      def java_signature_type(name, node, allow_void: false)
        return Java::void.java_class if allow_void && name == "void"

        primitive = primitive_java_class(name)
        return primitive if primitive

        entry = @classes_by_name[name.gsub(".", "::")] || @ir.classes.values.find do |candidate|
          class_name(candidate).tr("/", ".") == name
        end
        return JavaTypes::DeclaredType.new(class_name(entry).tr("/", "."), entry["id"]) if entry

        if name.end_with?("[]")
          component = java_signature_type(name.delete_suffix("[]"), node)
          return java.lang.reflect.Array.newInstance(component, 0).java_class
        end
        java_class = @java_imports[name] || try_java_lang(name)
        java_class ||= try_load_java_class(name)
        unsupported!(node, "Java type #{name} in java_signature") unless java_class
        java_class
      end

      # Return the reflected Java primitive class for a keyword, or nil for a nonprimitive name.
      def primitive_java_class(name)
        {
          "boolean" => Java::boolean.java_class, "byte" => Java::byte.java_class,
          "short" => Java::short.java_class, "char" => Java::char.java_class,
          "int" => Java::int.java_class, "long" => Java::long.java_class,
          "float" => Java::float.java_class, "double" => Java::double.java_class,
          "void" => Java::void.java_class
        }[name]
      end

      # Emit a previously resolved constructor, static, virtual, interface, or generated Java call.
      # Convert Java numeric results back to their logical Spinel representation.
      def emit_java_call(node)
        resolved = @java_calls.fetch(node.fetch("id"))
        return emit_generated_java_call(node, resolved) if resolved.fetch(:kind) == :generated

        if resolved.fetch(:kind) == :constructor
          constructor = resolved.fetch(:constructor)
          owner = constructor.declaring_class
          @method.new(owner)
          @method.dup
          emit_java_arguments(resolved.fetch(:arguments), constructor.parameter_types)
          @method.invokespecial(owner, "<init>", [Java::void, *constructor.parameter_types])
          return
        end

        java_method = resolved.fetch(:method)
        if resolved.fetch(:kind) == :instance
          receiver = resolved.fetch(:receiver)
          receiver && receiver >= 0 ? emit_expression(receiver) : @method.aload(0)
        end
        emit_java_arguments(resolved.fetch(:arguments), java_method.parameter_types)
        signature = [java_method.return_type, *java_method.parameter_types]
        if resolved.fetch(:kind) == :static
          @method.invokestatic(java_method.declaring_class, java_method.name, signature)
        elsif java_method.declaring_class.interface?
          @method.invokeinterface(java_method.declaring_class, java_method.name, signature)
        else
          @method.invokevirtual(java_method.declaring_class, java_method.name, signature)
        end
        emit_java_return_conversion(java_method.return_type.name)
      end

      # Evaluate arguments in source order and convert each value to its resolved Java parameter type.
      def emit_java_arguments(arguments, parameter_types)
        arguments.zip(parameter_types).each do |argument, parameter|
          emit_expression(argument)
          emit_java_argument_conversion(parameter.name)
        end
      end

      # Narrow Spinel long/double values to the Java int-category/float representation when required.
      def emit_java_argument_conversion(java_name)
        @method.l2i if %w[int short byte char].include?(java_name)
        @method.d2f if java_name == "float"
      end

      # Widen Java int-category/float results to Spinel's logical long/double representation.
      def emit_java_return_conversion(java_name)
        @method.i2l if %w[int short byte char].include?(java_name)
        @method.f2d if java_name == "float"
      end
    end
  end
end
