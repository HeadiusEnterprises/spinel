# frozen_string_literal: true

# Exercise boxed Ruby collections, strings, arithmetic, closures, object dispatch, and threads.

# Sparse growth, negative indexing, and Array.new's shared-vs-block fill.
a = [1, 2]
a[4] = 9
p a
p a[-1]
p a[-9]
shared = Array.new(2, [])
shared[0] << 7
p shared
fresh = Array.new(2) { [] }
fresh[0] << 9
p fresh

# Mutable identity, Unicode characters versus bytes, and copied hash keys.
s = +"x"
same = s
s << "é"
p [same, s.length, s.bytesize, s[1], s.getbyte(1)]
p 255.chr.getbyte(0)
key = +"key"
hash = {key => 1, :key => 2}
key << "!"
p [hash["key"], hash[:key], hash[key]]
pairs = []
hash.each { |pair| pairs << pair[1] }
p pairs
p([1, [2]] == [1.0, [2.0]])

# Negative division/modulo, mixed floats, and integer overflow promotion.
p [-7 / 3, 7 / -3, -7 % 3, 7 % -3, 1 + 2.5]
p 9223372036854775807 + 1
p -9223372036854775808 - 1
p 1000000000000000000000000000000 + 3

# Captures update the enclosing cell; block parameters shadow it; block
# locals are fresh on every invocation, including nested closures.
outer = 10
captured = []
[1, 2].each do |outer|
  fresh = nil
  fresh = (fresh || 0) + outer
  captured << fresh
  [3].each { |inner| captured << outer + inner }
end
p [outer, captured]

# Return through nested compiled blocks to the enclosing method's activation.
def nonlocal_return
  [1].each { [2].each { return 31 } }
  99
end
puts nonlocal_return

# Yield to a captured caller block so break can exit the yielding call.
def relay
  [1].each { yield }
  puts "unreachable"
end
p(relay { break 41 })
p([1, 2, 3].map { |n| next n * 2 if n == 2; n })

i = 0
result = while true
  i += 1
  next if i == 2
  break 9 if i == 3
end
p [i, result]
a, b = 1, 2
a, b = b, a
p [a, b]

# Defaults and keyword argument binding.
# Exercise positional defaults alongside required and optional keyword arguments.
def defaults(value = 3, left:, right: 4)
  value + left + right
end
p defaults(left: 2)
p defaults(1, left: 2, right: 3)

# Static define_method retains its lexical capture.
offset = 5
define_method(:captured_method) { |value| value + offset }
p captured_method(7)

# Module methods/constants, mixins, inherited initialization, and overrides.
# Provide a lexically resolved constant and an instance method through a mixin.
module Offset
  VALUE = 7
  # Resolve a constant through the included module's lexical scope.
  def offset
    VALUE
  end
end
# Supply inherited initialization, an accessor, and a mixed-in calculation.
class Base
  attr_accessor :value
  include Offset
  # Initialize an inherited polymorphic instance field.
  def initialize(value)
    @value = value
  end
  # Combine the receiver's current value with its mixed-in offset.
  def compute
    @value + offset
  end
end
# Override computation while retaining base storage and mixed-in behavior.
class Derived < Base
  # Override compute while reusing the inherited field and mixed-in method.
  def compute
    @value * 2 + offset
  end
end
item = Derived.new(5)
p item.compute
item.value = "mixed"
p item.value

# Exercise generated Struct accessors and mutable component storage.
Point = Struct.new(:x, :y)
point = Point.new(2, 3)
point.x = 7
p point.x + point.y
# Exercise a custom Struct method declared in its construction block.
Scaled = Struct.new(:x) do
  # Read a Struct component from a custom method defined in the construction block.
  def scale
    x * 2
  end
end
p Scaled.new(3).scale

# sort_by must evaluate each key once and preserve the order of equal keys.
calls = 0
sorted = [[2, :a], [1, :b], [2, :c]].sort_by { |pair| calls += 1; pair[0] }
p sorted
p calls

# Join independent workers through Thread#value and combine their returned values.
threads = (0...4).map do |index|
  Thread.new(index) { |n| [n, n * n] }
end
p threads.map { |thread| thread.value[1] }.sum
puts "core passed"
