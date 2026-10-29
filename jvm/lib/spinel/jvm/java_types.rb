# frozen_string_literal: true

require_relative "java_type_emitter"

module Spinel
  module JVM
    # Java ABI declarations use ordinary Ruby calls. This pass reads their
    # lexical class bodies, before reachability pruning or bytecode emission.
    module JavaTypes
      include JavaTypeEmitter

      JAVA_DIRECTIVES = %w[java_interface java_abstract java_record java_enum java_package].freeze
      OPS = BiteScript::ASM::Opcodes
      # Names a generated reference type before its JVM class can be loaded.
      DeclaredType = Struct.new(:name, :class_id) do
        # Identify a generated declaration as a reference type rather than a Java primitive.
        def primitive? = false
        # Identify a generated declaration as a non-array reference type.
        def array? = false
      end

      # Recognize Java imports, signatures, and type directives that do not execute at runtime.
      def java_compile_time_call?(node)
        java_import_call?(node) || java_signature_call?(node) ||
          (node["kind"] == "CallNode" && node.dig("references", "receiver") == -1 &&
           JAVA_DIRECTIVES.include?(node.dig("strings", "name")))
      end

      # Find all reopened class/module bodies, or the defining node for a record declaration.
      def class_body_nodes(entry)
        definition = @ir.node(entry.fetch("definition"))
        if %w[ClassNode ModuleNode].include?(definition["kind"])
          @ir.nodes.values.select do |node|
            %w[ClassNode ModuleNode].include?(node["kind"]) &&
              java_expression_name(@ir.node(node.dig("references", "constant_path"))) == entry["name"].gsub("::", ".")
          end
        else
          [definition]
        end
      end

      # Return direct class-body statements, unwrapping a Data.define block when necessary.
      def class_body_statements(node)
        if node["kind"] == "ConstantWriteNode"
          value = @ir.node(node.dig("references", "value"))
          block = value.dig("references", "block")
          return [] unless block && block >= 0

          node = @ir.node(block)
        end
        body = node.dig("references", "body")
        return [] unless body && body >= 0

        @ir.node(body).fetch("arrays").fetch("body", []).map { |id| @ir.node(id) }
      end

      # Initialize Java declaration tables and collect package, class, interface, record, and enum metadata.
      # Reject misplaced directives and includes that do not resolve to Java interfaces.
      def collect_java_type_declarations
        @java_type_kinds = {}
        @java_type_nodes = {}
        @java_parents = {}
        @java_interfaces = Hash.new { |hash, key| hash[key] = [] }
        @java_abstract_methods = Hash.new { |hash, key| hash[key] = [] }
        @java_records = {}
        @java_enums = {}
        recognized = collect_java_package
        @ir.classes.each_value { |entry| collect_java_class_declarations(entry, recognized) }
        validate_java_includes
        @ir.nodes.each_value do |node|
          next unless node["kind"] == "CallNode" && node.dig("references", "receiver") == -1
          next unless JAVA_DIRECTIVES.include?(node.dig("strings", "name"))
          next if recognized.include?(node["id"])

          unsupported!(node, "misplaced #{node.dig("strings", "name")} declaration")
        end
      end

      # Validate the optional top-level package name and return its recognized directive node IDs.
      def collect_java_package
        recognized = []
        top_ids = @ir.node(@ir.node(@ir.root).dig("references", "statements")).dig("arrays", "body")
        top_ids.each do |id|
          node = @ir.node(id)
          next unless node["kind"] == "CallNode" && top_level_call?(node, "java_package")

          arguments = call_arguments(node)
          unsupported!(node, "java_package without one literal package name") unless arguments.length == 1
          literal = @ir.node(arguments.first)
          require_kind!(literal, "StringNode")
          name = literal.dig("strings", "content")
          unless name.match?(/\A[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\z/)
            unsupported!(node, "invalid Java package #{name.inspect}")
          end
          unsupported!(node, "multiple java_package declarations") if @java_package
          @java_package = name.tr(".", "/")
          recognized << id
        end
        recognized
      end

      # Collect a class's Java marker, abstract methods, external superclass, and included interfaces.
      def collect_java_class_declarations(entry, recognized)
        bodies = class_body_nodes(entry)
        statements = bodies.flat_map { |body| class_body_statements(body) }
        directives = statements.select do |node|
          java_compile_time_call?(node) && JAVA_DIRECTIVES.include?(node.dig("strings", "name"))
        end
        markers = directives.select do |node|
          %w[java_interface java_record java_enum].include?(node.dig("strings", "name"))
        end
        unsupported!(markers.last, "multiple Java type markers") if markers.length > 1
        collect_java_type_marker(entry, statements, markers.first) if markers.first
        collect_java_abstract_methods(entry["id"], directives, recognized)
        collect_java_superclass(entry, bodies)
        collect_java_includes(entry, statements)
      end

      # Register one interface/record/enum marker and validate the permitted class-body shape.
      def collect_java_type_marker(entry, statements, marker)
        kind = marker.dig("strings", "name").delete_prefix("java_").to_sym
        @java_type_kinds[entry["id"]] = kind
        @java_type_nodes[entry["id"]] = marker
        statements.each do |statement|
          allowed = statement["kind"] == "DefNode" || java_compile_time_call?(statement) ||
                    (statement["kind"] == "CallNode" && top_level_call?(statement, "include"))
          unsupported!(statement, "class-body operation in Java #{kind}") unless allowed
        end
        definition = @ir.node(entry["definition"])
        case kind
        when :interface
          unsupported!(marker, "java_interface outside a module") unless definition["kind"] == "ModuleNode"
          unsupported!(marker, "java_interface arguments") unless call_arguments(marker).empty?
        when :record
          collect_java_record(entry, marker)
        when :enum
          collect_java_enum(entry, marker, definition)
        end
      end

      # Validate enum constant names and record their declaration order, rejecting instance fields.
      def collect_java_enum(entry, marker, definition)
        unsupported!(marker, "java_enum outside a class") unless definition["kind"] == "ClassNode"
        names = call_arguments(marker).map do |id|
          literal = @ir.node(id)
          require_kind!(literal, "SymbolNode")
          literal.dig("strings", "value")
        end
        valid_names = names.uniq == names && names.all? { |name| name.match?(/\A[A-Z][A-Za-z0-9_]*\z/) }
        unsupported!(marker, "invalid or duplicate Java enum constants") unless valid_names
        @java_enums[entry["id"]] = names
        unsupported!(marker, "instance fields on Java enum") unless entry["ivars"].empty?
      end

      # Parse public abstract interface signatures and track recognized class-level directives.
      def collect_java_abstract_methods(class_id, directives, recognized)
        directives.each do |node|
          case node.dig("strings", "name")
          when "java_abstract"
            unsupported!(node, "java_abstract outside a Java interface") unless @java_type_kinds[class_id] == :interface
            signature = parse_java_signature(node, abstract: true)
            unsupported!(node, "non-public abstract interface method") unless signature[:visibility] == :public
            @java_abstract_methods[class_id] << signature
          when "java_package"
            unsupported!(node, "java_package outside the top level")
          end
          recognized << node["id"]
        end
      end

      # Resolve an external superclass and require an extensible public class with an accessible empty constructor.
      def collect_java_superclass(entry, bodies)
        bodies.each do |body|
          parent = body.dig("references", "superclass")
          next unless parent && parent >= 0 && entry["parent"].negative?

          java_parent = java_class_value(@ir.node(parent))
          unsupported!(body, "unresolved Java superclass") unless java_parent
          unsupported!(body, "Java interface used as superclass; use include") if java_parent.interface?
          if java.lang.reflect.Modifier.final?(java_parent.modifiers)
            unsupported!(body, "extension of final Java class #{java_parent.name}")
          end
          unless java.lang.reflect.Modifier.public?(java_parent.modifiers)
            unsupported!(body,
                         "non-public Java superclass")
          end
          unless java_parent.declared_constructors.any? do |constructor|
            accessible_no_argument_constructor?(constructor)
          end
            unsupported!(body, "Java superclass without an accessible no-argument constructor")
          end
          @java_parents[entry["id"]] = java_parent
        end
      end

      # Check whether a constructor accepts no parameters and is public or protected.
      def accessible_no_argument_constructor?(constructor)
        constructor.parameter_types.empty? &&
          (java.lang.reflect.Modifier.public?(constructor.modifiers) ||
           java.lang.reflect.Modifier.protected?(constructor.modifiers))
      end

      # Resolve included generated or external types and add each interface only once.
      def collect_java_includes(entry, statements)
        statements.each do |node|
          next unless node["kind"] == "CallNode" && top_level_call?(node, "include")

          call_arguments(node).each do |argument|
            value = @ir.node(argument)
            name = java_expression_name(value)&.gsub(".", "::")
            type = @classes_by_name[name] || java_class_value(value)
            unsupported!(node, "unresolved included module/interface #{name}") unless type
            @java_interfaces[entry["id"]] << type unless @java_interfaces[entry["id"]].include?(type)
          end
        end
      end

      # Reject included types that are neither generated Java interfaces nor reflected Java interfaces.
      def validate_java_includes
        @java_interfaces.each_value do |types|
          types.each do |type|
            valid = type.is_a?(Hash) ? @java_type_kinds[type["id"]] == :interface : type.interface?
            raise UnsupportedNode, "JVM include currently requires a Java interface" unless valid
          end
        end
      end

      # Collect typed components from a named Data.define block in declaration order.
      # Require matching members, legal unique names, and no extra inferred instance fields.
      def collect_java_record(entry, marker)
        definition = @ir.node(entry["definition"])
        unless definition["kind"] == "ConstantWriteNode"
          unsupported!(marker,
                       "java_record outside a named Data.define block")
        end
        value = @ir.node(definition.dig("references", "value"))
        receiver_id = value.dig("references", "receiver")
        receiver = receiver_id && receiver_id >= 0 ? @ir.node(receiver_id) : nil
        unless receiver && receiver.dig("strings", "name") == "Data" && value.dig("strings", "name") == "define"
          unsupported!(marker, "java_record outside Data.define")
        end
        members = call_arguments(value).map do |id|
          literal = @ir.node(id)
          require_kind!(literal, "SymbolNode")
          literal.dig("strings", "value")
        end
        args = call_arguments(marker)
        unsupported!(marker, "java_record without component type keywords") unless args.length == 1
        keywords = @ir.node(args.first)
        require_kind!(keywords, "KeywordHashNode")
        components = keywords.dig("arrays", "elements").map do |id|
          pair = @ir.node(id)
          require_kind!(pair, "AssocNode")
          key = @ir.node(pair.dig("references", "key"))
          require_kind!(key, "SymbolNode")
          name = key.dig("strings", "value")
          type = java_type_expression(@ir.node(pair.dig("references", "value")), marker)
          unsupported!(marker, "void record component") unless type && type.name != "void"
          [name, type]
        end
        unless components.map(&:first) == members
          unsupported!(marker,
                       "record component names/order differ from Data.define")
        end
        forbidden = %w[clone finalize getClass hashCode notify notifyAll toString wait]
        unsupported!(marker, "invalid Java record component name") unless members.all? do |name|
          name.match?(/\A[a-zA-Z_$][\w$]*\z/) && !forbidden.include?(name)
        end
        unsupported!(marker, "duplicate record component") unless members.uniq == members
        unsupported!(marker, "additional record instance fields") unless entry["ivars"].map do |ivar|
          ivar["name"]
        end.sort == members.map { |name|
                      "@#{name}"
                    }.sort
        @java_records[entry["id"]] = components
      end

      # Attach a Java signature to a scope, retain its body for emission, and seed parameter types.
      def install_java_signature(scope, signature, node)
        unless scope.fetch("parameters").length == signature.fetch(:parameter_types).length
          unsupported!(node,
                       "java_signature parameter count")
        end
        @java_signatures[scope["id"]] = signature
        @instance_scopes << scope unless @instance_scopes.include?(scope)
        scope.fetch("parameters").zip(signature.fetch(:spinel_parameters)).each do |parameter, type|
          @java_local_types[[scope["id"], parameter["name"]]] = type
        end
      end

      # Return the generated and reflected interfaces explicitly associated with a class.
      def java_interfaces(entry)
        @java_interfaces.fetch(entry["id"], [])
      end

      # Find the external JVM superclass, including the implicit Record/Enum parent of marked types.
      def external_java_parent(class_id)
        return nil unless class_id && class_id >= 0
        return java.lang.Enum.java_class if @java_type_kinds[class_id] == :enum
        return java.lang.Record.java_class if @java_type_kinds[class_id] == :record

        while class_id >= 0
          return @java_parents[class_id] if @java_parents[class_id]

          class_id = @ir.classes.fetch(class_id)["parent"]
        end
        nil
      end

      # Check whether a generated class can be passed as the requested reflected Java reference type.
      def generated_java_assignable?(class_id, target)
        return true if target.name == "java.lang.Object"

        parent = external_java_parent(class_id)
        return true if parent && target.assignable_from?(parent)

        java_interfaces(@ir.classes.fetch(class_id)).any? do |type|
          type.is_a?(Hash) ? generated_java_assignable?(type["id"], target) : target.assignable_from?(type)
        end || (@ir.classes.fetch(class_id)["parent"] >= 0 && generated_java_assignable?(
          @ir.classes.fetch(class_id)["parent"], target
        ))
      end

      # Check generated superclass/interface ancestry while avoiding repeated nodes on the search path.
      def generated_subtype?(class_id, target_id, path = [])
        return true if class_id == target_id
        return false if path.include?(class_id)

        entry = @ir.classes.fetch(class_id)
        parent = entry["parent"]
        (parent >= 0 && generated_subtype?(parent, target_id, path + [class_id])) ||
          java_interfaces(entry).any? do |type|
            type.is_a?(Hash) && generated_subtype?(type["id"], target_id, path + [class_id])
          end
      end

      # Collect abstract, default, interface, and superclass method contracts for a generated type.
      # Reject interface-inheritance cycles and deduplicate full name/parameter/return descriptors.
      def java_contracts(entry, path = [])
        class_id = entry["id"]
        raise UnsupportedNode, "cyclic Java interface inheritance" if path.include?(class_id)

        contracts = @java_abstract_methods[class_id].map { |signature| signature.merge(abstract: true) }
        if @java_type_kinds[class_id] == :interface
          @all_instance_scopes.select { |scope| scope["class"] == class_id }.each do |scope|
            signature = @java_signatures[scope["id"]]
            contracts << signature.merge(abstract: false) if signature
          end
        end
        java_interfaces(entry).each do |type|
          if type.is_a?(Hash)
            contracts.concat(java_contracts(type, path + [class_id]))
          else
            contracts.concat(reflected_java_contracts(type))
          end
        end
        parent = external_java_parent(class_id)
        parent ||= java.lang.Object.java_class unless @java_type_kinds[class_id] == :interface
        contracts.concat(reflected_java_contracts(parent)) if parent
        contracts.uniq do |signature|
          [signature[:name], signature[:parameter_types].map(&:name), signature[:return_type].name]
        end
      end

      # Describe public and inherited protected instance methods using normalized Java contract metadata.
      def reflected_java_contracts(type)
        methods = type.java_send(:getMethods).to_a
        ancestor = type
        while ancestor
          methods.concat(ancestor.declared_methods.select do |method|
            java.lang.reflect.Modifier.protected?(method.modifiers)
          end)
          ancestor = ancestor.superclass
        end
        methods = methods.reject { |method| java.lang.reflect.Modifier.static?(method.modifiers) }.uniq do |method|
          [method.name, method.parameter_types.map(&:name), method.return_type.name]
        end
        methods.map do |method|
          {
            name: method.name,
            visibility: java.lang.reflect.Modifier.public?(method.modifiers) ? :public : :protected,
            exceptions: method.exception_types.to_a,
            parameter_types: method.parameter_types.to_a, return_type: method.return_type,
            spinel_parameters: method.parameter_types.map { |parameter| java_spinel_type(parameter, nil) },
            spinel_return: java_spinel_type(method.return_type, nil, allow_void: true),
            abstract: java.lang.reflect.Modifier.abstract?(method.modifiers),
            final: java.lang.reflect.Modifier.final?(method.modifiers)
          }
        end
      end

      # Infer unique inherited Java signatures for unannotated Spinel overrides.
      # Reject overloaded matches and omit analyzer-synthesized record methods from emitted bodies.
      def configure_java_contracts
        @ir.classes.each_value do |entry|
          contracts = java_contracts(entry)
          @all_instance_scopes.select { |scope| scope["class"] == entry["id"] }.each do |scope|
            next if @java_signatures.key?(scope["id"])

            matches = contracts.select do |signature|
              signature[:name] == scope["name"] && signature[:parameter_types].length == scope["parameters"].length
            end
            next if matches.empty?

            descriptors = matches.uniq do |signature|
              [signature[:parameter_types].map(&:name), signature[:return_type].name]
            end
            unless descriptors.length == 1
              unsupported!(@ir.node(scope["definition"]),
                           "overloaded Java override #{scope["name"]}; use java_signature")
            end
            install_java_signature(scope, descriptors.first, @ir.node(scope["definition"]))
          end
        end
        # Data's analyzer synthesizes Enumerable methods, which are not JVM
        # record members. Keep only source methods explicitly exported/called.
        @instance_scopes.reject! do |scope|
          @java_type_kinds[scope["class"]] == :record &&
            !@ir.node(scope["definition"]).dig("integers", "node_line")
        end
      end

      # Validate generated class shape, descriptors, inherited contracts, reserved members, and return values.
      def validate_java_exports
        @ir.classes.each_value do |entry|
          class_id = entry["id"]
          kind = @java_type_kinds[class_id]
          marker = @java_type_nodes[class_id] || @ir.node(entry["definition"])
          validate_java_class_shape(entry, kind, marker)
          validate_java_export_descriptors(class_id, marker)
          validate_java_contracts(entry, kind, marker)
          validate_reserved_java_members(class_id, kind)
        end
        @instance_scopes.each { |scope| validate_java_return(scope) }
      end

      # Reject unsupported inheritance, singleton methods, fields, and subclassing of final generated types.
      def validate_java_class_shape(entry, kind, marker)
        class_id = entry["id"]
        if %i[interface enum record].include?(kind)
          unsupported!(marker, "explicit superclass on Java #{kind}") if entry["parent"] >= 0 || @java_parents[class_id]
          if @ir.scopes.values.any? { |scope| scope["class"] == class_id && scope["class_method"] }
            unsupported!(marker, "singleton methods on Java #{kind}")
          end
        end
        validate_java_interface_methods(entry, marker) if kind == :interface
        parent_kind = @java_type_kinds[entry["parent"]]
        return unless entry["parent"] >= 0 && %i[enum record].include?(parent_kind)

        unsupported!(marker, "subclassing final Java #{parent_kind}")
      end

      # Require public explicit signatures for all emitted interface default-method bodies.
      def validate_java_interface_methods(entry, marker)
        unsupported!(marker, "instance fields on Java interface") unless entry["ivars"].empty?
        @all_instance_scopes.select { |scope| scope["class"] == entry["id"] }.each do |scope|
          definition = @ir.node(scope["definition"])
          signature = @java_signatures[scope["id"]]
          unsupported!(definition, "interface default method without java_signature") unless signature
          unsupported!(definition, "non-public Java interface default method") unless signature[:visibility] == :public
        end
      end

      # Return explicit or inferred Java export signatures declared by the specified class.
      def java_export_signatures(class_id)
        @instance_scopes.filter_map do |scope|
          @java_signatures[scope["id"]] if scope["class"] == class_id
        end
      end

      # Collect a generated class's exported signatures followed by those of its Spinel ancestors.
      def inherited_java_exports(class_id)
        exports = []
        while class_id >= 0
          exports.concat(java_export_signatures(class_id))
          class_id = @ir.classes.fetch(class_id)["parent"]
        end
        exports
      end

      # Build a Java overload key from a method name and its ordered parameter type names.
      def java_method_key(signature)
        [signature[:name], signature[:parameter_types].map(&:name)]
      end

      # Reject duplicate exported or abstract method names with identical parameter descriptors.
      def validate_java_export_descriptors(class_id, marker)
        signatures = java_export_signatures(class_id) + @java_abstract_methods[class_id]
        keys = signatures.map { |signature| java_method_key(signature) }
        unsupported!(marker, "duplicate exported Java method descriptor") unless keys.uniq == keys
      end

      # Check exported methods against inherited Java contracts and required abstract implementations.
      # Reject final-method overrides and incompatible return types or visibility.
      def validate_java_contracts(entry, kind, marker)
        exports = inherited_java_exports(entry["id"])
        contracts = java_contracts(entry)
        contracts.each do |contract|
          next if kind == :record && %w[equals hashCode toString].include?(contract[:name])

          matches = exports.select { |signature| java_method_key(signature) == java_method_key(contract) }
          if contract[:abstract] && kind != :interface
            validate_abstract_java_contract(entry["id"], contract, matches, contracts, marker)
          end
          matches.each do |signature|
            unsupported!(marker, "override of final Java method #{contract[:name]}") if contract[:final]
            next if compatible_java_override?(signature, contract)

            unsupported!(marker, "incompatible Java override #{contract[:name]}")
          end
        end
      end

      # Require an identical return type and visibility compatible with the inherited Java contract.
      def compatible_java_override?(signature, contract)
        signature[:return_type] == contract[:return_type] &&
          visibility_compatible?(signature[:visibility], contract[:visibility])
      end

      # Check whether a nonabstract signature implements the contract's exact name and types.
      def concrete_java_contract?(signature, contract)
        !signature[:abstract] && signature[:name] == contract[:name] &&
          signature[:parameter_types] == contract[:parameter_types] &&
          signature[:return_type] == contract[:return_type]
      end

      # Require a compatible exported body or an inherited concrete implementation of an abstract method.
      def validate_abstract_java_contract(class_id, contract, matches, contracts, marker)
        return if matches.any? { |signature| compatible_java_override?(signature, contract) }

        parent = external_java_parent(class_id) || java.lang.Object.java_class
        inherited = reflected_java_contracts(parent).any? { |signature| concrete_java_contract?(signature, contract) }
        inherited ||= contracts.any? { |signature| concrete_java_contract?(signature, contract) }
        return if inherited

        parameters = contract[:parameter_types].map(&:name).join(", ")
        unsupported!(marker, "missing Java interface/abstract method #{contract[:name]}(#{parameters})")
      end

      # Reject source methods that replace automatically generated record or enum members.
      def validate_reserved_java_members(class_id, kind)
        reserved = case kind
                   when :record then @java_records[class_id].map(&:first) + %w[equals hashCode toString initialize]
                   when :enum then %w[initialize values valueOf]
                   else []
                   end
        @all_instance_scopes.each do |scope|
          next unless scope["class"] == class_id && @ir.node(scope["definition"]).dig("integers", "node_line")

          name = @java_signatures.dig(scope["id"], :name) || scope["name"]
          if reserved.include?(name)
            unsupported!(@ir.node(scope["definition"]), "replacement of generated Java #{kind} member #{name}")
          end
        end
      end

      # Require a nonvoid exported method's final expression to convert to its declared Java return type.
      def validate_java_return(scope)
        signature = @java_signatures[scope["id"]]
        return unless signature && signature[:return_type].name != "void"

        body = @ir.node(scope["body"])
        last = body.dig("arrays", "body")&.last
        actual = last ? node_type(@ir.node(last)) : "nil"
        return if java_parameter_score(actual, signature[:return_type])

        unsupported!(@ir.node(scope["definition"]),
                     "return type #{actual} incompatible with java_signature #{signature[:return_type].name}")
      end

      # Allow public implementations, or protected implementations of protected inherited methods.
      def visibility_compatible?(actual, inherited)
        actual == :public || (actual == :protected && inherited == :protected)
      end

      # Refine analyzer types using Java self, enum constants, record fields, and resolved boundary calls.
      def boundary_node_type(node)
        case node["kind"]
        when "SelfNode"
          class_id = @ir.scope(node.dig("analysis", "scope"))["class"]
          return "object:#{class_id}" if class_id >= 0
        when "ConstantPathNode"
          entry, = java_enum_constant(node)
          return "object:#{entry["id"]}" if entry
        when "InstanceVariableReadNode"
          owner = @ir.scope(node.dig("analysis", "scope"))["class"]
          component = @java_records.fetch(owner, []).find { |name, _type| "@#{name}" == node.dig("strings", "name") }
          return java_spinel_type(component[1], node) if component
        when "CallNode"
          return boundary_call_type(node)
        end
        nil
      end

      # Infer constructor, member, and supported scalar-operation results at the Java boundary.
      def boundary_call_type(node)
        name = node.dig("strings", "name")
        receiver_id = node.dig("references", "receiver")
        arguments = call_arguments(node)
        if receiver_id == -1
          owner = @ir.scope(node.dig("analysis", "scope"))["class"]
          return boundary_member_type(owner, name, arguments, node)
        end
        return nil unless receiver_id && receiver_id >= 0

        receiver = @ir.node(receiver_id)
        entry = @classes_by_name[receiver.dig("strings", "name")] if receiver["kind"] == "ConstantReadNode"
        return "object:#{entry["id"]}" if entry && name == "new"

        type = node_type(receiver)
        if object_type?(type)
          result = boundary_member_type(object_class(type), name, arguments, node)
          return result if result
        end
        return type if arguments.length == 1 && %w[+ - * / %].include?(name) && %w[int float].include?(type)
        return "bool" if arguments.length == 1 && %w[< <= > >= == !=].include?(name)

        nil
      end

      # Infer a record accessor's result or a generated method's exported Java return type.
      def boundary_member_type(owner, name, arguments, node)
        component = @java_records.fetch(owner, []).find { |component_name, _type| component_name == name }
        return java_spinel_type(component[1], node) if component && arguments.empty?

        scope = find_instance_scope(owner, name, arguments.length) if owner >= 0
        @java_signatures.dig(scope["id"], :spinel_return) if scope && @java_signatures[scope["id"]]
      end

      # Check whether a generated class carries a Java interface, record, or enum marker.
      def java_type_declaration?(entry)
        @java_type_kinds.key?(entry["id"])
      end

      # Declare a generated interface builder or return an already reflected external interface.
      def java_interface_builder(file, type, path)
        type.is_a?(Hash) ? declare_class_builder(file, type["id"], path) : type
      end

      # Declare a Java interface, record, or enum with its resolved interfaces and superclass.
      # Set modern record/enum/final header flags directly through ASM before emitting members.
      def declare_java_type_builder(file, entry, path)
        kind = @java_type_kinds.fetch(entry["id"])
        interfaces = java_interfaces(entry).map { |type| java_interface_builder(file, type, path + [entry["id"]]) }
        klass = if kind == :interface
                  file.public_interface(class_name(entry), *interfaces)
                else
                  parent = kind == :record ? java.lang.Record : java.lang.Enum
                  file.public_class(class_name(entry), parent, *interfaces)
                end
        if kind != :interface
          # BiteScript predates records and has no final/enum class options.
          # ASM's header visitor can supply the modern flags before emission.
          flags = OPS::ACC_PUBLIC | OPS::ACC_FINAL | OPS::ACC_SUPER
          flags |= kind == :record ? OPS::ACC_RECORD : OPS::ACC_ENUM
          klass.instance_variable_get(:@class_writer).visit(
            BiteScript.bytecode_version, flags, klass.name, nil,
            BiteScript::Signature.path(klass.superclass),
            interfaces.map { |type| BiteScript::Signature.path(type) }.to_java(:string)
          )
        end
        @class_builders[entry["id"]] = klass
      end
    end
  end
end
