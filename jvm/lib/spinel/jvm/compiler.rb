# frozen_string_literal: true

require_relative "bitescript"
require_relative "ir"
require_relative "jar_writer"
require_relative "java_types"
require_relative "java_interop"
require_relative "range_iteration"
require_relative "unsupported_node"
require_relative "core_compiler"
require "jruby/compiler/java_signature"

module Spinel
  module JVM
    # Emits primitive JVM code and coordinates Java ABI declarations.
    class Compiler
      include JavaTypes
      include JavaInterop
      include RangeIteration

      MAIN_CLASS = "org/spinel/generated/SpinelMain"

      TYPES = {
        "int" => Java::long,
        "float" => Java::double,
        "bool" => Java::boolean,
        "string" => Java::java.lang.String
      }.freeze

      # Report whether this compilation selected primitive or boxed-core lowering.
      attr_reader :engine

      # Validate the target and classpath, then select boxed or primitive lowering.
      # The primitive path also resolves Java declarations and call signatures.
      def initialize(analyzed_ir, classpath: [], release: 17)
        @classpath = classpath.reject(&:empty?).map { |path| File.expand_path(path) }
        @classpath.each do |path|
          raise UnsupportedNode, "Java classpath entry does not exist: #{path}" unless File.exist?(path)
        end
        if CoreCompiler.required?(analyzed_ir)
          raise UnsupportedNode, "unsupported Java release #{release}; expected 17" unless release == 17

          @core_compiler = CoreCompiler.new(analyzed_ir)
          @engine = :core
          return
        end
        @engine = :primitive
        @ir = analyzed_ir
        @release = release
        raise UnsupportedNode, "unsupported Java release #{@release}; expected 17" unless @release == 17

        @top_scope = analyzed_ir.scope(0)
        @locals = {}
        @reachable_scopes = analyzed_ir.scopes.values.select do |scope|
          scope["id"] != 0 && scope["reachable"]
        end
        @method_scopes = @reachable_scopes.select { |scope| scope["class"] == -1 }
        @instance_scopes = @reachable_scopes.select do |scope|
          scope["class"] >= 0 && !scope["class_method"]
        end
        @all_instance_scopes = analyzed_ir.scopes.values.select do |scope|
          scope["class"] >= 0 && !scope["class_method"]
        end
        @classes_by_name = analyzed_ir.classes.values.to_h { |entry| [entry.fetch("name"), entry] }
        @class_builders = {}
        @java_imports = {}
        @java_calls = {}
        @java_node_types = {}
        @java_local_types = {}
        @java_signatures = {}
        configure_java_interop
      end

      # Write an executable JAR containing the generated classes and required runtime.
      # Delegate to the boxed compiler when the selected engine requires it.
      def compile(output)
        return @core_compiler.compile(output) if @core_compiler

        classes = {}
        compiler = self
        builder = BiteScript::FileBuilder.build(@ir.data["source_file"] || "source.rb") do
          compiler.__send__(:declare_class_builders, self)
          compiler.__send__(:emit_object_classes)
          compiler.__send__(:emit_main_class, self)
        end
        builder.generate do |filename, class_builder|
          classes[filename] = class_builder.generate
        end
        JarWriter.write(output, MAIN_CLASS.tr("/", "."), classes)
      end

      private

      # Select the generated class that owns top-level static methods.
      attr_writer :class_builder

      # Declare every generated type before emitting bodies that reference it.
      def declare_class_builders(file)
        @ir.classes.each_key { |class_id| declare_class_builder(file, class_id, []) }
      end

      # Return a cached builder or declare its superclass and interfaces first.
      # Track the inheritance path to reject cycles before creating class headers.
      def declare_class_builder(file, class_id, path)
        return @class_builders.fetch(class_id) if @class_builders.key?(class_id)
        if path.include?(class_id)
          raise UnsupportedNode,
                "cyclic class inheritance: #{(path + [class_id]).join(" -> ")}"
        end

        entry = @ir.classes.fetch(class_id)
        return declare_java_type_builder(file, entry, path) if java_type_declaration?(entry)

        parent_id = entry.fetch("parent")
        superclass = if parent_id >= 0
                       declare_class_builder(file, parent_id, path + [class_id])
                     else
                       @java_parents[class_id] || java.lang.Object
                     end
        interfaces = java_interfaces(entry).map { |type| java_interface_builder(file, type, path + [class_id]) }
        @class_builders[class_id] = file.public_class(class_name(entry), superclass, *interfaces)
      end

      # Define the JVM entry class and its static Spinel method implementations.
      def emit_main_class(file)
        klass = file.public_class(MAIN_CLASS)
        self.class_builder = klass
        klass.public_static_method(
          "main", [], Java::void, Java::java.lang.String[]
        ) { |method| emit_main(method) }
        emit_methods(klass)
      end

      # Emit declared fields, constructors, and methods for each generated type.
      def emit_object_classes
        @ir.classes.each_value do |entry|
          klass = @class_builders.fetch(entry.fetch("id"))
          if java_type_declaration?(entry)
            emit_java_type(klass, entry)
            next
          end
          declared_ivars(entry).each do |ivar|
            klass.public_field(field_name(ivar.fetch("name")), jvm_type(ivar.fetch("type"), ivar.fetch("name")))
          end
          emit_constructor(klass, entry)
          emit_instance_methods(klass, entry)
        end
      end

      # Emit a no-argument JVM constructor that initializes the chosen superclass.
      def emit_constructor(klass, entry)
        parent_id = entry.fetch("parent")
        superclass = if parent_id >= 0
                       @class_builders.fetch(parent_id)
                     else
                       @java_parents[entry["id"]] || java.lang.Object
                     end
        klass.public_constructor([]) do |method|
          method.aload(0)
          method.invokespecial(superclass, "<init>", [Java::void])
          method.returnvoid
        end
      end

      # Emit reachable instance methods using inferred or explicit Java descriptors.
      # Convert exported return values to their declared Java representation.
      def emit_instance_methods(klass, entry)
        @instance_scopes.each do |scope|
          next unless scope["class"] == entry["id"]

          signature = @java_signatures[scope.fetch("id")]
          visibility = signature ? signature.fetch(:visibility) : :public
          exceptions = signature ? signature.fetch(:exceptions) : []
          klass.public_send(
            "#{visibility}_method",
            instance_method_name(scope), exceptions,
            effective_jvm_return_type(scope),
            *parameter_types(scope)
          ) do |method|
            with_scope(method, scope) do
              allocate_locals(scope)
              if signature && java_type_name(signature.fetch(:return_type)) == "void"
                emit_statements(scope.fetch("body"))
              else
                emit_statements_value(scope.fetch("body"))
              end
              emit_scope_return(scope)
            end
          end
        end
      end

      # Allocate top-level locals and emit the program body as Java's main method.
      def emit_main(method)
        with_scope(method, @top_scope) do
          method.local("argv", Java::java.lang.String[])
          allocate_locals(@top_scope)
          emit_statements(@ir.node(@ir.root).fetch("references").fetch("statements"))
          method.returnvoid
        end
      end

      # Emit reachable top-level Spinel methods as typed static JVM methods.
      def emit_methods(klass)
        @method_scopes.each do |scope|
          return_type = jvm_return_type(scope.fetch("return_type"), scope.fetch("name"))
          klass.public_static_method(
            method_name(scope), [], return_type, *parameter_types(scope)
          ) do |method|
            with_scope(method, scope) do
              allocate_locals(scope)
              emit_statements_value(scope.fetch("body"))
              emit_return(scope.fetch("return_type"))
            end
          end
        end
      end

      # Return explicit Java parameter types or validate and map inferred parameters.
      def parameter_types(scope)
        signature = @java_signatures[scope.fetch("id")]
        return signature.fetch(:parameter_types) if signature

        scope.fetch("parameters").map do |parameter|
          local = scope.fetch("locals").find { |entry| entry["name"] == parameter["name"] }
          raise UnsupportedNode, "missing inferred parameter #{parameter["name"]}" unless local
          raise UnsupportedNode, "default arguments are not supported yet" unless parameter["default"] == -1

          jvm_type(local.fetch("type"), parameter.fetch("name"))
        end
      end

      # Run emission with fresh method-local state, restoring the previous state afterward.
      def with_scope(method, scope)
        previous = [@method, @scope, @locals, @label_counter]
        @method = method
        @scope = scope
        @locals = {}
        @label_counter = 0
        yield
      ensure
        @method, @scope, @locals, @label_counter = previous
      end

      # Assign JVM slots to parameters first, followed by other inferred locals.
      # Retain both physical Java types and logical Spinel types for conversions.
      def allocate_locals(scope)
        parameters = scope.fetch("parameters").map { |entry| entry.fetch("name") }
        local_names = scope.fetch("locals").map { |entry| entry.fetch("name") }
        ordered = parameters + (local_names - parameters)
        ordered.each do |name|
          local = scope.fetch("locals").find { |entry| entry["name"] == name }
          logical_type = effective_local_type(scope, local)
          signature = @java_signatures[scope.fetch("id")]
          parameter_index = parameters.index(name)
          physical_type = if signature && parameter_index
                            signature.fetch(:parameter_types).fetch(parameter_index)
                          else
                            jvm_type(logical_type, name)
                          end
          @locals[name] = [@method.local(name, physical_type), physical_type, logical_type]
        end
      end

      # Emit a statement list without leaving unused expression values on the stack.
      def emit_statements(id)
        node = @ir.node(id)
        require_kind!(node, "StatementsNode")
        node.fetch("arrays").fetch("body").each { |child| emit_statement(child) }
      end

      # Emit one statement, consuming values and skipping separately emitted declarations.
      def emit_statement(id)
        node = @ir.node(id)
        mark_line(node)
        case node.fetch("kind")
        when "DefNode", "ClassNode", "ModuleNode"
          # Class and method declarations are emitted in their dedicated passes.
        when "ConstantWriteNode"
          entry = @classes_by_name[node.dig("strings", "name")]
          unsupported!(node, "constant assignment") unless entry && @java_type_kinds[entry["id"]] == :record
        when "LocalVariableWriteNode"
          emit_expression(node.fetch("references").fetch("value"))
          store_local(node.fetch("strings").fetch("name"))
        when "InstanceVariableWriteNode"
          emit_ivar_write(node, false)
        when "CallNode"
          if java_compile_time_call?(node)
            # Compile-time declarations; resolved before bytecode emission.
          elsif range_each?(node)
            emit_range_each(node)
          elsif top_level_call?(node, "puts")
            emit_puts(node)
          else
            emit_expression(id)
            discard(node_type(node))
          end
        when "WhileNode", "UntilNode"
          emit_loop(node)
        when "IfNode", "UnlessNode"
          emit_if_statement(node)
        else
          emit_expression(id)
          discard(node_type(node))
        end
      end

      # Emit one primitive or reference expression, leaving its value on the operand stack.
      def emit_expression(id)
        node = @ir.node(id)
        mark_line(node)
        case node.fetch("kind")
        when "IntegerNode"
          @method.ldc_long(node.fetch("integers").fetch("value"))
        when "FloatNode"
          @method.ldc_double(Float(node.fetch("content")))
        when "StringNode"
          @method.ldc(node.fetch("strings").fetch("content"))
        when "TrueNode"
          @method.iconst_1
        when "FalseNode"
          @method.iconst_0
        when "LocalVariableReadNode"
          load_local(node.fetch("strings").fetch("name"))
        when "LocalVariableWriteNode"
          name = node.fetch("strings").fetch("name")
          emit_expression(node.fetch("references").fetch("value"))
          duplicate(node_type(node))
          store_local(name)
        when "SelfNode"
          @method.aload(0)
        when "InstanceVariableReadNode"
          emit_ivar_read(node)
        when "InstanceVariableWriteNode"
          emit_ivar_write(node, true)
        when "CallNode"
          emit_call(node)
        when "ConstantPathNode"
          emit_java_enum_constant(node)
        when "NilNode"
          @method.aconst_null
        when "IfNode", "UnlessNode"
          emit_if(node)
        when "ParenthesesNode"
          emit_statements_value(node.fetch("references").fetch("body"))
        else
          unsupported!(node, "expression")
        end
      end

      # Emit a nonempty statement list and retain only its final expression value.
      def emit_statements_value(id)
        statements = @ir.node(id).fetch("arrays").fetch("body")
        raise UnsupportedNode, "empty value-producing statement list" if statements.empty?

        statements[0...-1].each { |child| emit_statement(child) }
        emit_expression(statements.last)
      end

      # Select Java, arithmetic, constructor, virtual, or top-level call emission.
      # Primitive integer arithmetic uses checked JDK operations where available.
      def emit_call(node)
        name = node.fetch("strings").fetch("name")
        receiver = node.fetch("references").fetch("receiver")
        args = call_arguments(node)
        type = node_type(node)

        if @java_calls.key?(node.fetch("id"))
          emit_java_call(node)
        elsif receiver >= 0 && args.length == 1 && %w[+ - * / %].include?(name)
          emit_expression(receiver)
          emit_expression(args.first)
          integer_method = {
            ["int", "+"] => "addExact",
            ["int", "-"] => "subtractExact",
            ["int", "*"] => "multiplyExact",
            ["int", "%"] => "floorMod"
          }[[type, name]]
          if integer_method
            @method.invokestatic(
              java.lang.Math, integer_method, [Java::long, Java::long, Java::long]
            )
            return
          end
          opcode = {
            ["float", "+"] => :dadd, ["float", "-"] => :dsub,
            ["float", "*"] => :dmul, ["float", "/"] => :ddiv,
            ["float", "%"] => :drem
          }.fetch([type, name]) { unsupported!(node, "#{type} #{name}") }
          @method.public_send(opcode)
        elsif receiver >= 0 && args.length == 1 && %w[< <= > >= == !=].include?(name)
          emit_comparison(node, receiver, args.first, name)
        elsif receiver >= 0 && constructor_call?(node, receiver, name)
          emit_constructor_call(node, receiver, args)
        elsif receiver >= 0 && object_type?(node_type(@ir.node(receiver)))
          emit_instance_call(node, receiver, name, args)
        elsif receiver == -1 && @scope.fetch("class") >= 0 &&
              record_accessor?(@ir.classes.fetch(@scope.fetch("class")), name, args)
          type = @java_records.fetch(@scope.fetch("class")).to_h.fetch(name)
          @method.aload(0)
          @method.invokevirtual(@class_builders.fetch(@scope.fetch("class")), name, [type])
          emit_java_return_conversion(type.name)
        elsif receiver == -1 && @scope.fetch("class") >= 0 &&
              find_instance_scope(@scope.fetch("class"), name, args.length)
          emit_bare_instance_call(name, args, node)
        elsif receiver == -1
          emit_direct_call(node, name, args)
        else
          unsupported!(node, "call #{name}")
        end
      end

      # Recognize construction of a class declared in the current compilation.
      def constructor_call?(_node, receiver, name)
        name == "new" && @ir.node(receiver)["kind"] == "ConstantReadNode" &&
          @classes_by_name.key?(@ir.node(receiver).fetch("strings").fetch("name"))
      end

      # Allocate a generated object and invoke its JVM constructor.
      # Then call the resolved Spinel initialize method while retaining the new object.
      def emit_constructor_call(node, receiver, args)
        constant = @ir.node(receiver).fetch("strings").fetch("name")
        entry = @classes_by_name.fetch(constant)
        return emit_record_construction(node, entry, args) if @java_type_kinds[entry["id"]] == :record

        kind = @java_type_kinds[entry["id"]]
        unsupported!(node, "construction of Java #{kind}") if %i[interface enum].include?(kind)
        scope = find_instance_scope(entry.fetch("id"), "initialize", args.length)
        unsupported!(node, "unresolved constructor #{constant}/#{args.length}") unless scope || args.empty?
        klass = @class_builders.fetch(entry.fetch("id"))
        @method.new(klass)
        @method.dup
        @method.invokespecial(klass, "<init>", [Java::void])
        return unless scope

        @method.dup
        args.each { |argument| emit_expression(argument) }
        signature = [jvm_return_type(scope.fetch("return_type"), "initialize"), *parameter_types(scope)]
        @method.invokevirtual(@class_builders.fetch(scope.fetch("class")), instance_method_name(scope), signature)
        discard(scope.fetch("return_type"))
      end

      # Return the Java-flow override for a local, falling back to its inferred type.
      def effective_local_type(scope, local)
        @java_local_types.fetch([scope.fetch("id"), local.fetch("name")], local.fetch("type"))
      end

      # Emit a generated receiver's accessor or resolved virtual/interface call.
      # Validate exported arguments and convert values at Java signature boundaries.
      def emit_instance_call(node, receiver, name, args)
        class_id = object_class(node_type(@ir.node(receiver)))
        entry = @ir.classes.fetch(class_id)
        return emit_record_accessor(node, receiver, entry, name, args) if record_accessor?(entry, name, args)

        ivar_name = "@#{name.delete_suffix("=")}"
        ivar_owner, ivar = find_ivar_with_owner(entry, ivar_name)
        if ivar && args.empty? && name == name.delete_suffix("=")
          emit_expression(receiver)
          @method.getfield(@class_builders.fetch(ivar_owner.fetch("id")), field_name(ivar_name),
                           jvm_type(ivar.fetch("type"), ivar_name))
          return
        elsif ivar && args.length == 1 && name.end_with?("=")
          type = jvm_type(ivar.fetch("type"), ivar_name)
          emit_expression(receiver)
          emit_expression(args.first)
          type_category2?(type) ? @method.dup2_x1 : @method.dup_x1
          @method.putfield(@class_builders.fetch(ivar_owner.fetch("id")), field_name(ivar_name), type)
          return
        end
        target = find_instance_scope(class_id, name, args.length)
        unsupported!(node, "unresolved instance call #{entry["name"]}##{name}/#{args.length}") unless target
        emit_expression(receiver)
        target_parameters = parameter_types(target)
        args.zip(target_parameters).each do |argument, parameter|
          if @java_signatures[target["id"]] && !java_parameter_score(node_type(@ir.node(argument)), parameter)
            unsupported!(node, "argument incompatible with java_signature parameter #{parameter.name}")
          end
          emit_expression(argument)
          emit_java_argument_conversion(java_type_name(parameter))
        end
        target_return = effective_jvm_return_type(target)
        signature = [target_return, *target_parameters]
        owner = @class_builders.fetch(target.fetch("class"))
        @method.public_send(owner.interface? ? :invokeinterface : :invokevirtual, owner, instance_method_name(target),
                            signature)
        emit_java_return_conversion(java_type_name(target_return)) if @java_signatures.key?(target.fetch("id"))
      end

      # Invoke a resolved method on self using its inferred or exported Java descriptor.
      def emit_bare_instance_call(name, args, node)
        target = find_instance_scope(@scope.fetch("class"), name, args.length)
        @method.aload(0)
        target_parameters = parameter_types(target)
        args.zip(target_parameters).each do |argument, parameter|
          if @java_signatures[target["id"]] && !java_parameter_score(node_type(@ir.node(argument)), parameter)
            unsupported!(node, "argument incompatible with java_signature parameter #{parameter.name}")
          end
          emit_expression(argument)
          emit_java_argument_conversion(java_type_name(parameter))
        end
        target_return = effective_jvm_return_type(target)
        signature = [target_return, *target_parameters]
        owner = @class_builders.fetch(target.fetch("class"))
        @method.public_send(owner.interface? ? :invokeinterface : :invokevirtual, owner, instance_method_name(target),
                            signature)
        emit_java_return_conversion(java_type_name(target_return)) if @java_signatures.key?(target.fetch("id"))
      end

      # Find the nearest method with the requested name and arity along the superclass chain.
      def find_instance_scope(class_id, name, arity)
        current = class_id
        while current && current >= 0
          found = @instance_scopes.find do |scope|
            scope["class"] == current && scope["name"] == name &&
              scope.fetch("parameters").length == arity
          end
          return found if found

          current = @ir.classes.fetch(current).fetch("parent")
        end
        nil
      end

      # Return inherited instance-variable metadata without its declaring class.
      def find_ivar(entry, name)
        _owner, ivar = find_ivar_with_owner(entry, name)
        ivar
      end

      # Find an instance variable's original declaring class and inferred field metadata.
      def find_ivar_with_owner(entry, name)
        current = entry
        while current
          found = current.fetch("ivars").find { |ivar| ivar["name"] == name }
          parent = current.fetch("parent")
          if found
            ancestor = parent >= 0 ? @ir.classes.fetch(parent) : nil
            inherited_owner, inherited = ancestor ? find_ivar_with_owner(ancestor, name) : [nil, nil]
            return [inherited_owner, inherited] if inherited

            return [current, found]
          end
          current = parent >= 0 ? @ir.classes.fetch(parent) : nil
        end
        [nil, nil]
      end

      # Return fields introduced by this class, excluding inherited storage.
      def declared_ivars(entry)
        parent_id = entry.fetch("parent")
        return entry.fetch("ivars") if parent_id.negative?

        parent = @ir.classes.fetch(parent_id)
        entry.fetch("ivars").reject { |ivar| find_ivar(parent, ivar.fetch("name")) }
      end

      # Read a record component or generated instance field and normalize its value.
      def emit_ivar_read(node)
        components = @java_records.fetch(@scope["class"], [])
        component = components.find { |name, _type| "@#{name}" == node.dig("strings", "name") }
        if component
          name, type = component
          @method.aload(0)
          @method.getfield(@class_builders.fetch(@scope["class"]), name, type)
          emit_java_return_conversion(type.name)
          return
        end
        entry, ivar = current_ivar(node)
        @method.aload(0)
        @method.getfield(@class_builders.fetch(entry.fetch("id")), field_name(ivar.fetch("name")),
                         jvm_type(ivar.fetch("type"), ivar.fetch("name")))
      end

      # Store an instance field, optionally retaining the assigned value; reject record mutation.
      def emit_ivar_write(node, keep_value)
        unsupported!(node, "mutation of Java record components") if @java_type_kinds[@scope["class"]] == :record
        entry, ivar = current_ivar(node)
        type = jvm_type(ivar.fetch("type"), ivar.fetch("name"))
        @method.aload(0)
        emit_expression(node.fetch("references").fetch("value"))
        (type_category2?(type) ? @method.dup2_x1 : @method.dup_x1) if keep_value
        @method.putfield(@class_builders.fetch(entry.fetch("id")), field_name(ivar.fetch("name")), type)
      end

      # Resolve a field against the current class or reject invalid instance-variable access.
      def current_ivar(node)
        class_id = @scope.fetch("class")
        unsupported!(node, "instance variable outside an instance method") if class_id.negative?
        current = @ir.classes.fetch(class_id)
        owner, ivar = find_ivar_with_owner(current, node.fetch("strings").fetch("name"))
        unsupported!(node, "unknown instance variable #{node.dig("strings", "name")}") unless ivar
        [owner, ivar]
      end

      # Resolve a unique top-level method by name and arity, then emit a static call.
      def emit_direct_call(node, name, args)
        candidates = @method_scopes.select do |scope|
          scope["name"] == name && scope.fetch("parameters").length == args.length
        end
        unsupported!(node, "unresolved call #{name}/#{args.length}") unless candidates.length == 1
        target = candidates.first
        args.each { |argument| emit_expression(argument) }
        signature = [jvm_return_type(target.fetch("return_type"), name)]
        target.fetch("parameters").each do |parameter|
          local = target.fetch("locals").find { |entry| entry["name"] == parameter["name"] }
          signature << jvm_type(local.fetch("type"), parameter.fetch("name"))
        end
        @method.invokestatic(@class_builder, method_name(target), signature)
      end

      # Compare long or double operands and leave a JVM boolean on the stack.
      # Choose the floating comparison opcode so ordered comparisons handle NaN correctly.
      def emit_comparison(node, receiver, argument, operator)
        operand_type = node_type(@ir.node(receiver))
        emit_expression(receiver)
        emit_expression(argument)
        compare_opcode, jump_opcode = if operand_type == "int"
                                        [:lcmp, comparison_jump(operator)]
                                      elsif operand_type == "float"
                                        float_compare = %w[< <=].include?(operator) ? :dcmpg : :dcmpl
                                        [float_compare, comparison_jump(operator)]
                                      else
                                        unsupported!(node, "#{operand_type} comparison")
                                      end
        @method.public_send(compare_opcode)
        yes = fresh_label("comparison_true")
        done = fresh_label("comparison_done")
        @method.public_send(jump_opcode, yes)
        @method.iconst_0
        @method.goto(done)
        @method.label(yes)
        @method.iconst_1
        @method.label(done)
      end

      # Map a comparison operator to the branch instruction used after a JVM numeric comparison.
      def comparison_jump(operator)
        {
          "<" => :iflt, "<=" => :ifle, ">" => :ifgt, ">=" => :ifge,
          "==" => :ifeq, "!=" => :ifne
        }.fetch(operator)
      end

      # Emit a value-producing conditional; both supported branches must produce a value.
      def emit_if(node)
        predicate = node.fetch("references").fetch("predicate")
        then_body = node.fetch("references").fetch("statements")
        subsequent = node.fetch("references").fetch(
          node["kind"] == "UnlessNode" ? "else_clause" : "subsequent"
        )
        alternative = fresh_label("if_alternative")
        done = fresh_label("if_done")
        emit_boolean(predicate)
        branch = node["kind"] == "UnlessNode" ? :ifne : :ifeq
        @method.public_send(branch, alternative)
        emit_statements_value(then_body)
        @method.goto(done)
        @method.label(alternative)
        if subsequent == -1
          unsupported!(node, "nil-valued conditional")
        else
          other = @ir.node(subsequent)
          require_kind!(other, "ElseNode")
          emit_statements_value(other.fetch("references").fetch("statements"))
        end
        @method.label(done)
      end

      # Emit if/unless branches for side effects without requiring a result value.
      def emit_if_statement(node)
        predicate = node.fetch("references").fetch("predicate")
        then_body = node.fetch("references").fetch("statements")
        alternate_key = node["kind"] == "UnlessNode" ? "else_clause" : "subsequent"
        subsequent = node.fetch("references").fetch(alternate_key)
        alternative = fresh_label("if_statement_alternative")
        done = fresh_label("if_statement_done")
        emit_boolean(predicate)
        branch = node["kind"] == "UnlessNode" ? :ifne : :ifeq
        @method.public_send(branch, alternative)
        emit_statements(then_body)
        @method.goto(done)
        @method.label(alternative)
        if subsequent != -1
          other = @ir.node(subsequent)
          require_kind!(other, "ElseNode")
          emit_statements(other.fetch("references").fetch("statements"))
        end
        @method.label(done)
      end

      # Emit a pre-tested while/until loop with a boolean condition.
      def emit_loop(node)
        head = fresh_label("loop_head")
        done = fresh_label("loop_done")
        @method.label(head)
        emit_boolean(node.fetch("references").fetch("predicate"))
        branch = node["kind"] == "UntilNode" ? :ifne : :ifeq
        @method.public_send(branch, done)
        emit_statements(node.fetch("references").fetch("statements"))
        @method.goto(head)
        @method.label(done)
      end

      # Validate that a condition is inferred as boolean before emitting its value.
      def emit_boolean(id)
        node = @ir.node(id)
        unsupported!(node, "non-boolean condition") unless node_type(node) == "bool"
        emit_expression(id)
      end

      # Select the return instruction for a Spinel primitive, reference, or void result.
      def emit_return(type)
        case type
        when "int" then @method.lreturn
        when "float" then @method.dreturn
        when "bool" then @method.ireturn
        when "string" then @method.areturn
        when "nil", "void" then @method.returnvoid
        else
          unless object_type?(type) || java_reference_type?(type)
            raise UnsupportedNode, "unsupported return type #{type.inspect}"
          end

          @method.areturn

        end
      end

      # Convert and return an exported Java result, or use the scope's inferred return type.
      def emit_scope_return(scope)
        signature = @java_signatures[scope.fetch("id")]
        return emit_return(scope.fetch("return_type")) unless signature

        type = signature.fetch(:return_type)
        name = java_type_name(type)
        emit_java_argument_conversion(name)
        case name
        when "void" then @method.returnvoid
        when "long" then @method.lreturn
        when "double" then @method.dreturn
        when "float" then @method.freturn
        when "boolean", "int", "short", "byte", "char" then @method.ireturn
        else @method.areturn
        end
      end

      # Encode a top-level Spinel name with its scope ID to form a JVM-safe method name.
      def method_name(scope)
        safe = scope.fetch("name").encode("UTF-8").bytes.map do |byte|
          character = byte.chr
          character.match?(/[A-Za-z0-9_]/) ? character : "_#{byte.to_s(16)}"
        end.join
        "sp$#{scope.fetch("id")}$#{safe}"
      end

      # Use an exported Java name or a JVM-safe Spinel name qualified by arity.
      def instance_method_name(scope)
        signature = @java_signatures[scope.fetch("id")]
        return signature.fetch(:name) if signature

        safe = scope.fetch("name").encode("UTF-8").bytes.map do |byte|
          character = byte.chr
          character.match?(/[A-Za-z0-9_]/) ? character : "_#{byte.to_s(16)}"
        end.join
        "sp$#{safe}$#{scope.fetch("parameters").length}"
      end

      # Build a JVM-safe class name within the declared or default generated package.
      def class_name(entry)
        safe = entry.fetch("name").encode("UTF-8").bytes.map do |byte|
          character = byte.chr
          character.match?(/[A-Za-z0-9_$]/) ? character : "_#{byte.to_s(16)}"
        end.join
        "#{@java_package || "org/spinel/generated"}/#{safe}"
      end

      # Translate a Ruby instance-variable name into a generated JVM field name.
      def field_name(name)
        "sp$#{name.delete_prefix("@")}"
      end

      # Create a method-local branch label with a readable prefix and unique suffix.
      def fresh_label(prefix)
        @label_counter += 1
        :"#{prefix}_#{@label_counter}"
      end

      # Emit PrintStream.println calls using the inferred JVM type of each argument.
      def emit_puts(node)
        args = call_arguments(node)
        if args.empty?
          @method.getstatic(java.lang.System, "out", java.io.PrintStream)
          @method.invokevirtual(java.io.PrintStream, "println", [Java::void])
          return
        end
        args.each do |argument|
          type_name = node_type(@ir.node(argument))
          type = object_type?(type_name) ? java.lang.Object : jvm_type(type_name, "puts argument")
          @method.getstatic(java.lang.System, "out", java.io.PrintStream)
          emit_expression(argument)
          @method.invokevirtual(java.io.PrintStream, "println", [Java::void, type])
        end
      end

      # Return a call's argument node IDs, or an empty list when no argument node exists.
      def call_arguments(node)
        args_id = node.fetch("references").fetch("arguments", -1)
        return [] if args_id == -1

        @ir.node(args_id).fetch("arrays").fetch("arguments")
      end

      # Recognize a named call without an explicit receiver.
      def top_level_call?(node, name)
        node.fetch("strings").fetch("name") == name &&
          node.fetch("references").fetch("receiver") == -1
      end

      # Load a JVM local and widen Java numeric parameters to their logical Spinel representation.
      def load_local(name)
        index, type, logical_type = @locals.fetch(name) { raise UnsupportedNode, "unknown local #{name}" }
        case java_type_name(type)
        when "long" then @method.lload(index)
        when "double" then @method.dload(index)
        when "float"
          @method.fload(index)
          @method.f2d if logical_type == "float"
        when "boolean" then @method.iload(index)
        when "int", "short", "byte", "char"
          @method.iload(index)
          @method.i2l if logical_type == "int"
        else @method.aload(index)
        end
      end

      # Narrow logical Spinel values when necessary and store them in the local's JVM slot.
      def store_local(name)
        index, type, logical_type = @locals.fetch(name) { raise UnsupportedNode, "unknown local #{name}" }
        case java_type_name(type)
        when "long" then @method.lstore(index)
        when "double" then @method.dstore(index)
        when "float"
          @method.d2f if logical_type == "float"
          @method.fstore(index)
        when "boolean" then @method.istore(index)
        when "int", "short", "byte", "char"
          @method.l2i if logical_type == "int"
          @method.istore(index)
        else @method.astore(index)
        end
      end

      # Duplicate a value using the one-slot or two-slot opcode for its Spinel type.
      def duplicate(type)
        %w[int float].include?(type) ? @method.dup2 : @method.dup
      end

      # Pop a value using its JVM width, ignoring types that leave no stack value.
      def discard(type)
        return if %w[nil void unknown].include?(type)

        %w[int float].include?(type) ? @method.pop2 : @method.pop
      end

      # Attach a positive source line number to the next emitted bytecode instruction.
      def mark_line(node)
        line = node.fetch("integers", {})["node_line"]
        @method.line(line) if line&.positive?
      end

      # Return the most specific Java-flow, boundary, or analyzed type available for a node.
      def node_type(node)
        java_type = @java_node_types[node.fetch("id")]
        return java_type if java_type

        if %w[LocalVariableReadNode LocalVariableWriteNode].include?(node["kind"])
          key = [node.dig("analysis", "scope"), node.dig("strings", "name")]
          return @java_local_types[key] if @java_local_types.key?(key)
        end
        boundary_node_type(node) || node.fetch("analysis").fetch("type")
      end

      # Resolve a Spinel type to a Java class or generated builder, rejecting unsupported types.
      def jvm_type(type, context)
        return @class_builders.fetch(object_class(type)) if object_type?(type)
        return load_java_class_by_name(type.delete_prefix("java:"), context) if java_reference_type?(type)

        TYPES.fetch(type) do
          raise UnsupportedNode, "unsupported inferred type #{type.inspect} for #{context}"
        end
      end

      # Check whether a logical type identifies a generated Spinel object class.
      def object_type?(type)
        type.start_with?("object:")
      end

      # Check whether a logical type identifies an external Java reference.
      def java_reference_type?(type)
        type.start_with?("java:")
      end

      # Extract the generated class ID from an object type tag.
      def object_class(type)
        Integer(type.delete_prefix("object:"), 10)
      end

      # Check whether a JVM type occupies two operand-stack slots.
      def type_category2?(type)
        type == Java::long || type == Java::double
      end

      # Obtain the binary type name from a Java class, proxy, or generated type builder.
      def java_type_name(type)
        type.respond_to?(:name) && type.name ? type.name : type.java_class.name
      end

      # Map nil/void results to JVM void and resolve all other return types normally.
      def jvm_return_type(type, context)
        return Java::void if %w[nil void].include?(type)

        jvm_type(type, context)
      end

      # Prefer an explicit Java return type over the scope's inferred Spinel return type.
      def effective_jvm_return_type(scope)
        signature = @java_signatures[scope.fetch("id")]
        return signature.fetch(:return_type) if signature

        jvm_return_type(scope.fetch("return_type"), scope.fetch("name"))
      end

      # Reject a node whose syntax kind differs from the required lowering input.
      def require_kind!(node, expected)
        return if node["kind"] == expected

        raise UnsupportedNode, "expected #{expected}, got #{node["kind"]}"
      end

      # Raise an unsupported-feature error with the source location, operation, and node identity.
      def unsupported!(node, operation)
        line = node.fetch("integers", {})["node_line"] || 0
        raise UnsupportedNode,
              "#{@ir.data["source_file"]}:#{line}: JVM backend does not yet support " \
              "#{operation} (#{node["kind"]} node #{node["id"]})"
      end
    end
  end
end
