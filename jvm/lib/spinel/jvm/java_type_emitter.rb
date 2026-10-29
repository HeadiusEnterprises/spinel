# frozen_string_literal: true

module Spinel
  module JVM
    # Emits Java interface, record, and enum members after validation.
    module JavaTypeEmitter
      OPS = BiteScript::ASM::Opcodes

      private

      # Emit marked Java members and then the generated type's source-defined instance methods.
      def emit_java_type(klass, entry)
        case @java_type_kinds.fetch(entry["id"])
        when :interface
          @java_abstract_methods[entry["id"]].each do |signature|
            method = klass.method(OPS::ACC_PUBLIC | OPS::ACC_ABSTRACT, signature[:name],
                                  [signature[:return_type], *signature[:parameter_types]], signature[:exceptions])
            method.method_visitor.visit_end
          end
        when :record then emit_java_record(klass, entry)
        when :enum then emit_java_enum(klass, entry)
        end
        emit_instance_methods(klass, entry)
      end

      # Recognize an argument-free call to one of a record's declared components.
      def record_accessor?(entry, name, args)
        args.empty? && @java_records.fetch(entry["id"], []).any? { |component_name, _type| component_name == name }
      end

      # Invoke a generated record accessor and widen its Java numeric result when needed.
      def emit_record_accessor(_node, receiver, entry, name, _args)
        type = @java_records.fetch(entry["id"]).to_h.fetch(name)
        emit_expression(receiver)
        @method.invokevirtual(@class_builders.fetch(entry["id"]), name, [type])
        emit_java_return_conversion(type.name)
      end

      # Validate component arity/types, allocate a record, and invoke its canonical JVM constructor.
      def emit_record_construction(node, entry, args)
        components = @java_records.fetch(entry["id"])
        unsupported!(node, "record constructor arity") unless args.length == components.length
        args.zip(components).each do |argument, (_name, type)|
          unsupported!(node, "record argument incompatible with #{type.name}") unless java_parameter_score(
            node_type(@ir.node(argument)), type
          )
        end
        klass = @class_builders.fetch(entry["id"])
        @method.new(klass)
        @method.dup
        types = components.map(&:last)
        emit_java_arguments(args, types)
        @method.invokespecial(klass, "<init>", [Java::void, *types])
      end

      # Resolve a qualified constant to its generated enum class and declared constant name.
      def java_enum_constant(node)
        return nil unless node["kind"] == "ConstantPathNode"

        parent = @ir.node(node.dig("references", "parent"))
        entry = @classes_by_name[java_expression_name(parent)&.gsub(".", "::")]
        name = node.dig("strings", "name")
        return nil unless entry && @java_enums.fetch(entry["id"], []).include?(name)

        [entry, name]
      end

      # Load a generated enum's static constant field, rejecting other constant-path expressions.
      def emit_java_enum_constant(node)
        entry, name = java_enum_constant(node)
        unsupported!(node, "non-enum constant expression") unless entry
        klass = @class_builders.fetch(entry["id"])
        @method.getstatic(klass, name, klass)
      end

      # Resolve generated interface calls and enum valueOf operations before external Java lookup.
      def resolve_generated_java_call(node)
        receiver_id = node.dig("references", "receiver")
        class_id = if receiver_id == -1
                     @ir.scope(node.dig("analysis", "scope"))["class"]
                   elsif receiver_id && receiver_id >= 0
                     type = node_type(@ir.node(receiver_id))
                     object_class(type) if object_type?(type)
                   end
        if @java_type_kinds[class_id] == :interface
          resolved = resolve_generated_interface_call(node, class_id, receiver_id)
          return resolved if resolved
        end
        return nil unless receiver_id && receiver_id >= 0

        receiver = @ir.node(receiver_id)
        entry = @classes_by_name[receiver.dig("strings", "name")] if receiver["kind"] == "ConstantReadNode"
        name = node.dig("strings", "name")
        if entry && @java_type_kinds[entry["id"]] == :enum && name == "valueOf"
          arguments = call_arguments(node)
          unless arguments.length == 1 && node_type(@ir.node(arguments.first)) == "string"
            unsupported!(node,
                         "enum valueOf without one string")
          end
          return { kind: :generated, owner: entry["id"], name: name, arguments: arguments,
                   spinel_return: "object:#{entry["id"]}" }
        end
        nil
      end

      # Select an interface contract by inferred conversions or exact java_send parameter types.
      # Break conversion ties by reference specificity and report unresolved ambiguity.
      def resolve_generated_interface_call(node, class_id, receiver)
        name = node.dig("strings", "name")
        arguments = call_arguments(node)
        exact_types = nil
        if name == "java_send"
          name, exact_types, arguments = generated_java_send_arguments(node, arguments)
        elsif find_instance_scope(class_id, name, arguments.length)
          return nil
        end
        candidates = java_contracts(@ir.classes.fetch(class_id)).select do |signature|
          signature[:name] == name && signature[:parameter_types].length == arguments.length &&
            (!exact_types || signature[:parameter_types].map(&:name) == exact_types.map(&:name))
        end
        ranked = candidates.filter_map do |signature|
          scores = arguments.zip(signature[:parameter_types]).map do |argument, type|
            java_parameter_score(node_type(@ir.node(argument)), type)
          end
          [scores.sum, signature] unless scores.any?(&:nil?)
        end.sort_by(&:first)
        if ranked.empty?
          unsupported!(node, "unresolved exact Java interface method #{name}") if exact_types
          return nil
        end
        tied = ranked.take_while { |score, _signature| score == ranked.first[0] }
        if tied.length > 1
          specific = tied.select do |_score, candidate|
            tied.all? do |_other_score, other|
              candidate.equal?(other) || more_specific_parameters?(candidate[:parameter_types], other[:parameter_types])
            end
          end
          unless specific.length == 1
            unsupported!(node,
                         "ambiguous Java interface call #{name}; use java_send for an exact method")
          end
          ranked = specific
        end
        signature = ranked.first[1]
        { kind: :generated, owner: class_id, signature: signature, receiver: receiver,
          arguments: arguments, spinel_return: signature[:spinel_return] }
      end

      # Normalize exact interface-call arguments to a method name, parameter types, and value node IDs.
      def generated_java_send_arguments(node, arguments)
        unsupported!(node, "java_send without a method name") if arguments.empty?
        literal = @ir.node(arguments.first)
        unless %w[SymbolNode StringNode].include?(literal["kind"])
          unsupported!(node, "java_send method name that is not a symbol or string literal")
        end
        name = literal.dig("strings", literal["kind"] == "SymbolNode" ? "value" : "content")
        return [name, [], []] if arguments.length == 1

        types = @ir.node(arguments[1])
        require_kind!(types, "ArrayNode")
        exact_types = types.dig("arrays", "elements").map { |id| java_type_expression(@ir.node(id), node) }
        arguments = arguments.drop(2)
        unless exact_types.length == arguments.length
          unsupported!(node, "java_send argument count does not match parameter types")
        end
        [name, exact_types, arguments]
      end

      # Emit a generated interface invocation or enum lookup using its resolved JVM descriptor.
      def emit_generated_java_call(_node, resolved)
        klass = @class_builders.fetch(resolved[:owner])
        if (signature = resolved[:signature])
          resolved[:receiver] >= 0 ? emit_expression(resolved[:receiver]) : @method.aload(0)
          emit_java_arguments(resolved[:arguments], signature[:parameter_types])
          @method.invokeinterface(klass, signature[:name], [signature[:return_type], *signature[:parameter_types]])
          emit_java_return_conversion(signature[:return_type].name)
          return
        end
        emit_java_arguments(resolved[:arguments], [java.lang.String.java_class])
        @method.invokestatic(klass, resolved[:name], [klass, java.lang.String])
      end

      # Load a local using the opcode required by its physical Java primitive or reference type.
      def load_java_slot(method, slot, type)
        instruction = case type.name
                      when "long" then :lload
                      when "double" then :dload
                      when "float" then :fload
                      when "boolean", "int", "short", "byte", "char" then :iload
                      else :aload
                      end
        method.public_send(instruction, slot)
      end

      # Return a value using the opcode required by its physical Java type, including void.
      def return_java_value(method, type)
        instruction = case type.name
                      when "void" then :returnvoid
                      when "long" then :lreturn
                      when "double" then :dreturn
                      when "float" then :freturn
                      when "boolean", "int", "short", "byte", "char" then :ireturn
                      else :areturn
                      end
        method.public_send(instruction)
      end

      # Emit component metadata, final fields, accessors, and the canonical record constructor.
      # Use the JDK ObjectMethods bootstrap for equals, hashCode, and toString.
      def emit_java_record(klass, entry)
        components = @java_records.fetch(entry["id"])
        writer = klass.instance_variable_get(:@class_writer)
        components.each do |name, type|
          writer.visit_record_component(name, BiteScript::Signature.ci(type), nil).visit_end
          klass.private_final_field(name, type)
          klass.public_method(name, [], type) do |method|
            method.aload(0)
            method.getfield(klass, name, type)
            return_java_value(method, type)
          end
        end
        klass.public_constructor([], *components.map(&:last)) do |method|
          components.map(&:first).each { |name| method.method_visitor.visit_parameter(name, 0) }
          method.aload(0)
          method.invokespecial(java.lang.Record, "<init>", [Java::void])
          components.each do |name, type|
            slot = method.local(name, type)
            method.aload(0)
            load_java_slot(method, slot, type)
            method.putfield(klass, name, type)
          end
          method.returnvoid
        end

        # Use the JDK's record bootstrap, as javac does, for primitive-aware
        # equality, hashing, and the conventional component rendering.
        bootstrap = BiteScript::ASM::Handle.new(
          OPS::H_INVOKESTATIC, "java/lang/runtime/ObjectMethods", "bootstrap",
          "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/TypeDescriptor;" \
          "Ljava/lang/Class;Ljava/lang/String;[Ljava/lang/invoke/MethodHandle;)Ljava/lang/Object;", false
        )
        arguments = [BiteScript::ASM::Type.get_object_type(klass.name), components.map(&:first).join(";")]
        components.each do |name, type|
          arguments << BiteScript::ASM::Handle.new(OPS::H_GETFIELD, klass.name, name, BiteScript::Signature.ci(type),
                                                   false)
        end
        [["equals", Java::boolean, java.lang.Object], ["hashCode", Java::int],
         ["toString", java.lang.String]].each do |name, type, *parameters|
          klass.method(OPS::ACC_PUBLIC | OPS::ACC_FINAL, name, [type, *parameters], []) do |method|
            method.aload(0)
            method.aload(method.local("other", java.lang.Object)) if name == "equals"
            descriptor = BiteScript::Signature.sig(type, klass, *parameters)
            method.method_visitor.visit_invoke_dynamic_insn(name, descriptor, bootstrap,
                                                            arguments.to_java(java.lang.Object))
            return_java_value(method, type.java_class)
          end
        end
      end

      # Declare enum constant fields and emit construction, static initialization, and lookup helpers.
      def emit_java_enum(klass, entry)
        names = @java_enums.fetch(entry["id"])
        array_type = BiteScript::ASM::Type.get_type("[L#{klass.name};")
        names.each { |name| klass.field(OPS::ACC_PUBLIC | OPS::ACC_STATIC | OPS::ACC_FINAL | OPS::ACC_ENUM, name, klass) }
        klass.field(OPS::ACC_PRIVATE | OPS::ACC_STATIC | OPS::ACC_FINAL | OPS::ACC_SYNTHETIC, "$VALUES", array_type)
        emit_enum_constructor(klass)
        emit_enum_constants(klass, names, array_type)
        emit_enum_accessors(klass, names, array_type)
      end

      # Emit the private name/ordinal constructor delegating to java.lang.Enum.
      def emit_enum_constructor(klass)
        klass.private_constructor([], java.lang.String, Java::int) do |method|
          name_slot = method.local("name", java.lang.String)
          ordinal_slot = method.local("ordinal", Java::int)
          method.aload(0)
          method.aload(name_slot)
          method.iload(ordinal_slot)
          method.invokespecial(java.lang.Enum, "<init>", [Java::void, java.lang.String, Java::int])
          method.returnvoid
        end
      end

      # Construct enum instances in declaration order and populate the synthetic values array.
      def emit_enum_constants(klass, names, array_type)
        klass.static_init do |method|
          names.each_with_index do |name, ordinal|
            method.new(klass)
            method.dup
            method.ldc(name)
            method.ldc(ordinal)
            method.invokespecial(klass, "<init>", [Java::void, java.lang.String, Java::int])
            method.putstatic(klass, name, klass)
          end
          method.ldc(names.length)
          method.anewarray(klass)
          names.each_with_index do |name, index|
            method.dup
            method.ldc(index)
            method.getstatic(klass, name, klass)
            method.aastore
          end
          method.putstatic(klass, "$VALUES", array_type)
          method.returnvoid
        end
      end

      # Emit values with a defensive array copy and valueOf through the JDK enum lookup.
      def emit_enum_accessors(klass, names, array_type)
        klass.public_static_method("values", [], array_type) do |method|
          # Arrays.copyOf preserves the runtime array type and returns a copy.
          method.getstatic(klass, "$VALUES", array_type)
          method.ldc(names.length)
          method.invokestatic(java.util.Arrays, "copyOf", [java.lang.Object[], java.lang.Object[], Java::int])
          method.checkcast(array_type)
          method.areturn
        end
        klass.public_static_method("valueOf", [], klass, java.lang.String) do |method|
          slot = method.local("name", java.lang.String)
          method.ldc(BiteScript::ASM::Type.get_object_type(klass.name))
          method.aload(slot)
          method.invokestatic(java.lang.Enum, "valueOf", [java.lang.Enum, java.lang.Class, java.lang.String])
          method.checkcast(klass)
          method.areturn
        end
      end
    end
  end
end
