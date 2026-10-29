# Exercise inherited field initialization and virtual calls to an overridden instance method.

# Store a value and call its reader virtually from an inherited method.
class BaseValue
  # Initialize storage inherited by generated subclasses.
  def initialize(value)
    @value = value
  end

  # Return the base implementation's stored value.
  def value
    @value
  end

  # Call value virtually so a subclass override changes the computed result.
  def result
    value + 1
  end
end

# Reuse base initialization while changing the virtual reader implementation.
class DoubleValue < BaseValue
  # Override value so calls from the inherited result method dispatch here.
  def value
    @value * 2
  end
end

item = DoubleValue.new(10)
puts item.result
