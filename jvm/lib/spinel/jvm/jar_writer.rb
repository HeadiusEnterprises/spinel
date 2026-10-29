# frozen_string_literal: true

require "java"

module Spinel
  module JVM
    # Writes standalone JARs with stable class ordering and timestamps.
    module JarWriter
      module_function

      # Write a main-class manifest and sorted class entries, closing the JAR stream even on failure.
      def write(path, main_class, classes)
        manifest = java.util.jar.Manifest.new
        attributes = manifest.main_attributes
        attributes.put(java.util.jar.Attributes::Name::MANIFEST_VERSION, "1.0")
        attributes.put(java.util.jar.Attributes::Name::MAIN_CLASS, main_class)

        stream = java.util.jar.JarOutputStream.new(
          java.io.FileOutputStream.new(path), manifest
        )
        classes.sort.each do |name, bytes|
          entry = java.util.jar.JarEntry.new(name)
          entry.time = 0
          stream.put_next_entry(entry)
          stream.write(bytes.to_java_bytes)
          stream.close_entry
        end
      ensure
        stream&.close
      end
    end
  end
end
