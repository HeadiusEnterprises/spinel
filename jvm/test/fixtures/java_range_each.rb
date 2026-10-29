# Exercise Java-enabled range loops, captured locals, parameter shadowing, and terminal bounds.

require "java"

# Java timing and captured locals in a repeated, finite benchmark loop.
pass = 0
i = 99
while pass < 3
  started = System.currentTimeMillis
  sum = 0
  (1..10_000).each { |i| sum = sum + (i % 7) }
  puts sum
  puts System.currentTimeMillis - started >= 0
  pass = pass + 1
end
puts i

sum = 0
(-3..3).each { |i| sum = sum + (i % 7) }
puts sum
puts -7 % 3
puts 7 % -3
puts -7 % -3
puts (-9223372036854775807 - 1) % -1

sum = 0
(1...4).each { |i| sum = sum + i }
(4..1).each { |i| sum = sum + 100 }
(4...4).each { |i| sum = sum + 100 }
puts sum

# Endpoint expressions run once; changing bounds or the block parameter
# inside the block must not change the induction variable or trip count.
first = 1
last = 3
sum = 0
(first..last).each do |i|
  sum = sum + i
  i = 100
  first = 100
  last = 100
end
puts sum
puts first
puts last
puts i

# Nested block parameters shadow each other, not the enclosing local.
sum = 0
(1..2).each do |i|
  (3..4).each { |i| sum = sum + i }
  sum = sum + i
end
puts sum
puts i

sum = 0
(1..3).each { sum = sum + 2 }
(1..2).each { |i; extra| extra = i + 1; sum = sum + extra }
puts sum

# Inclusive terminal bounds must not wrap the induction variable.
count = 0
(9223372036854775807..9223372036854775807).each { |i| count = count + 1 }
(9223372036854775806...9223372036854775807).each { |i| count = count + 1 }
puts count

# Exercise range-block capture of instance-method parameters and locals.
class RangeCounter
  # Accumulate an inlined integer range inside a generated instance method.
  def sum(limit)
    total = 0
    (1..limit).each { |i| total = total + i }
    total
  end
end
puts RangeCounter.new.sum(5)
