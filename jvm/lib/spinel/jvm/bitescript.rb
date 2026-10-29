# frozen_string_literal: true

# BiteScript 0.1.4 predates the module, record, and post-Java-7 constants in
# modern ASM.  Its bytecode adapter enumerates every constant and rejects
# names it does not know, even when those names are not instructions.  Load
# the adapter against the instruction set it understands, while retaining the
# modern ASM bundled with JRuby for class writing and frame computation.
require "bitescript/asm"

# Ruby 4 removed the Fixnum constant. BiteScript uses it only as the integer
# arm of its LDC dispatcher, so the historical name remains a valid alias.
Object.const_set(:Fixnum, Integer) unless Object.const_defined?(:Fixnum)

# Spinel compiler components and backend adapters.
module Spinel
  # JVM bytecode generation, Java integration, and runtime packaging.
  module JVM
    # Hides metadata constants from BiteScript's legacy opcode discovery.
    module BiteScriptCompatibility
      LEGACY_CLASSFILE_CONSTANTS = /\AV1_[1-7]\z/
      MODERN_METADATA_CONSTANTS = %w[
        ACC_MANDATED ACC_MODULE ACC_OPEN ACC_RECORD ACC_STATIC_PHASE
        ACC_TRANSITIVE SOURCE_DEPRECATED SOURCE_MASK V_PREVIEW
      ].freeze

      # Return only constants understood by BiteScript's legacy instruction discovery.
      def constants(inherit = true)
        super.reject do |name|
          text = name.to_s
          MODERN_METADATA_CONSTANTS.include?(text) ||
            (text.start_with?("ASM") && text != "ASM4") ||
            (text.start_with?("V") && !LEGACY_CLASSFILE_CONSTANTS.match?(text))
        end
      end
    end
  end
end

BiteScript::ASM::Opcodes.singleton_class.prepend(
  Spinel::JVM::BiteScriptCompatibility
)

require "bitescript/signature"
require "bitescript/bytecode"
require "bitescript/builder"
require "bitescript/mirror"

# Configure ASM frame computation for every emitted method.
module BiteScript
  class << self
    # Report the selected classfile version and ASM frame/max-stack computation settings.
    attr_reader :bytecode_version
    attr_accessor :compute_frames, :compute_maxs

    # Select the classfile version and keep ASM frame computation enabled.
    def bytecode_version=(version)
      @bytecode_version = version
      self.compute_frames = true
    end
  end

  target = if ASM::Opcodes.const_defined?(:V17)
             ASM::Opcodes::V17
           else
             ASM::Opcodes::V1_8
           end
  self.bytecode_version = target
  self.compute_maxs = true
end

# BiteScript 0.1.4 makes every interface method abstract and discards its body.
# Java 8+ default methods need an ordinary instance method with code instead.
module Spinel
  module JVM
    # Keeps Java interface default-method bodies instead of marking them abstract.
    module DefaultInterfaceMethods
      # Emit supplied interface bodies as default methods; preserve legacy handling otherwise.
      def method(flags, name, signature, exceptions, &block)
        return super unless interface? && block

        builder = BiteScript::MethodBuilder.new(self, flags, name, exceptions, signature)
        methods[name] ||= {}
        methods[name][signature.drop(1)] = builder
        builder.local("this", self)
        builder.start
        block.call(builder)
        builder.stop
        builder
      end
    end
  end
end

BiteScript::ClassBuilder.prepend(Spinel::JVM::DefaultInterfaceMethods)
