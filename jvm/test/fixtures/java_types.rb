# Exercise exported interfaces, records, enums, and Java inheritance in one compilation.

require "java"
java_package "example.spinel"
java_import "java.lang.Runnable", "java.util.TimerTask"

# Export an interface with an abstract member and typed default implementations.
module Greeter
  java_interface
  java_abstract "String greet(String name)"

  java_signature "public long twice(long value)"
  # Provide an explicitly typed default interface method with primitive arithmetic.
  def twice(value)
    result = value * 2
    result
  end

  java_signature "public String welcome(String name)"
  # Invoke the interface's abstract greet contract from a default method.
  def welcome(name)
    greet(name)
  end
end

# Extend an external Java class and implement external and generated interfaces.
class Worker < TimerTask
  include Runnable, Greeter

  # The unique Runnable/TimerTask descriptor supplies void run().
  # Implement the inherited void Runnable/TimerTask contract with an observable side effect.
  def run
    puts "running"
  end

  java_signature "public String greet(String name)"
  # Implement the generated Greeter interface's String-valued contract.
  def greet(name)
    name
  end
end

# Export a record with primitive components and an additional typed instance method.
Point = Data.define(:x, :y) do
  java_record x: Java::long, y: Java::double

  java_signature "public long twiceX()"
  # Read a generated record component from a source-defined exported method.
  def twice_x
    x * 2
  end
end

# Exercise canonical record construction with int, float, boolean, and String components.
Primitives = Data.define(:small, :ratio, :flag, :label) do
  java_record small: Java::int, ratio: Java::float, flag: Java::boolean, label: java.lang.String
end

# Exercise a generated record type in an exported parameter and return descriptor.
class PointIdentity
  java_signature "public Point identity(Point value)"
  # Preserve a generated record reference across a Java signature boundary.
  def identity(value)
    value
  end
end

# Invoke a generated interface contract implemented by either Java or Spinel.
class GreetingClient
  java_signature "public String invoke(Greeter greeter, String name)"
  # Call a generated interface using java_send with exact String parameter selection.
  def invoke(greeter, name)
    greeter.java_send(:greet, [java.lang.String], name)
  end
end

# Export overloaded abstract methods distinguished by reference parameter types.
module Picker
  java_interface
  java_abstract "String pick(Object value)"
  java_abstract "String pick(CharSequence value)"
end

# Exercise inferred and exact overload selection on generated interfaces.
class PickingClient
  java_signature "public String choose(Picker picker)"
  # Select the more-specific CharSequence overload using inferred argument types.
  def choose(picker)
    picker.pick("value")
  end

  java_signature "public String chooseObject(Picker picker)"
  # Select the Object overload explicitly rather than the more-specific reference alternative.
  def choose_object(picker)
    picker.java_send(:pick, [java.lang.Object], "value")
  end
end

# Export enum constants and a source-defined instance method.
class Color
  java_enum :RED, :GREEN, :BLUE

  java_signature "public long code()"
  # Expose an ordinary source-defined instance method on generated enum constants.
  def code
    42
  end
end

point = Point.new(3, 4.0)
puts point.x
puts point.y
puts Color::RED.name
puts Color.valueOf("BLUE").ordinal
thread = Thread.new(Worker.new)
puts thread.isAlive
