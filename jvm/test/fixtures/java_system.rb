# Exercise the implicit java.lang import boundary with a direct System timing call.

require "java"

puts System.currentTimeMillis
