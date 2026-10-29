package org.spinel.runtime;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.UncheckedIOException;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.StringJoiner;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Runtime values for operations that require Ruby identity, nil, or boxing.
 * Program bodies and closures are JVM methods, not interpreted syntax trees.
 */
public final class Core {
  private Core() {}

  /** Entry point shared by generated method bodies. */
  public interface Program {
    Object invoke(int id, Environment env, Object[] args, Block block);
  }
  /** Captured body with optional receiver rebinding. */
  public interface Block {
    Object call(Object[] args);
    default Object callWithSelf(Object self, Object[] args) {
      return call(args);
    }
  }
  public static final Object[] EMPTY = new Object[0];
  /** Lexical slots, receiver, and nonlocal jump targets for one activation. */
  public static final class Environment {
    public final State state;
    public final Environment parent;
    public final Object self;
    public final RubyClass lexical;
    public final Object[] slots;
    public final Block block;
    public final Environment method;
    final Thread owner = Thread.currentThread();
    Object breakTarget;
    public boolean active = true;
    Environment(State state, Environment parent, Object self, RubyClass lexical, int size,
        Block block, Environment method) {
      this.state = state;
      this.parent = parent;
      this.self = self;
      this.lexical = lexical;
      this.slots = new Object[size];
      this.block = block;
      this.method = method == null ? this : method;
    }
  }
  /** Constants, globals, and top-level functions belonging to one program. */
  public static final class State {
    public final Program program;
    final Map<String, Object> constants = new HashMap<>();
    final Map<String, Object> globals = Collections.synchronizedMap(new HashMap<>());
    final Map<String, RubyMethod> functions = new HashMap<>();
    State(Program program) {
      this.program = program;
    }
  }
  public static class RubyObject {
    public final RubyClass klass;
    final Map<String, Object> ivars = new HashMap<>();
    RubyObject(RubyClass klass) {
      this.klass = klass;
    }
  }
  public static final class RubyClass extends RubyObject {
    final String name;
    final RubyClass parent;
    final RubyClass lexical;
    final Map<String, Object> constants = new HashMap<>();
    final Map<String, RubyMethod> methods = new HashMap<>(), singleton = new HashMap<>();
    final Set<String> readers = new HashSet<>(), writers = new HashSet<>();
    final List<RubyClass> includes = new ArrayList<>();
    String[] members;
    boolean data;
    RubyClass(String name, RubyClass parent, RubyClass lexical) {
      super(null);
      this.name = name;
      this.parent = parent;
      this.lexical = lexical;
    }
    @Override
    public String toString() {
      return name;
    }
  }
  static final class RubyMethod {
    final int id, slots;
    final RubyClass lexical;
    Environment captured;
    RubyMethod(int id, int slots, RubyClass lexical) {
      this.id = id;
      this.slots = slots;
      this.lexical = lexical;
    }
  }
  public static final class RubySymbol {
    final String name;
    RubySymbol(String name) {
      this.name = name;
    }
    @Override
    public boolean equals(Object b) {
      return b instanceof RubySymbol && name.equals(((RubySymbol) b).name);
    }
    @Override
    public int hashCode() {
      return name.hashCode();
    }
    @Override
    public String toString() {
      return name;
    }
  }
  /** Byte-oriented string storage; literals retain Spinel's frozen policy. */
  public static final class RubyString {
    byte[] bytes;
    int length;
    final boolean frozen, binary;
    RubyString(byte[] bytes, boolean frozen, boolean binary) {
      this.bytes = bytes;
      this.length = bytes.length;
      this.frozen = frozen;
      this.binary = binary;
    }
    byte[] copyBytes() {
      return Arrays.copyOf(bytes, length);
    }
    void mutable() {
      if (frozen)
        throw new IllegalStateException("FrozenError: can't modify frozen String");
    }
    RubyString append(Object value) {
      mutable();
      byte[] added = value instanceof Number ? new byte[] {(byte) integer(value).intValueExact()}
                                             : str(value).copyBytes();
      int needed = Math.addExact(length, added.length);
      if (needed > bytes.length)
        bytes = Arrays.copyOf(bytes, Math.max(needed, Math.max(16, bytes.length * 2)));
      System.arraycopy(added, 0, bytes, length, added.length);
      length = needed;
      return this;
    }
    @Override
    public String toString() {
      return new String(bytes, 0, length, StandardCharsets.UTF_8);
    }
    @Override
    public boolean equals(Object other) {
      return other instanceof RubyString
          && Arrays.equals(copyBytes(), ((RubyString) other).copyBytes());
    }
    @Override
    public int hashCode() {
      return Arrays.hashCode(copyBytes());
    }
  }
  /** Growable indexed storage with Ruby's negative-index and sparse-write rules. */
  public static final class RubyArray {
    Object[] values;
    int start, size;
    RubyArray(int size, Object fill) {
      if (size < 0)
        throw new IllegalArgumentException("ArgumentError: negative array size");
      values = new Object[size];
      this.size = size;
      Arrays.fill(values, fill);
    }
    RubyArray(Object[] values) {
      this.values = values.clone();
      this.size = values.length;
    }
    Object get(long i) {
      if (i < 0)
        i += size;
      return i < 0 || i >= size ? null : values[start + (int) i];
    }
    Object set(long index, Object value) {
      if (index < 0)
        index += size;
      if (index < 0)
        throw new IndexOutOfBoundsException("IndexError: index too small for array");
      int i = Math.toIntExact(index);
      ensure(Math.addExact(i, 1));
      if (i >= size) {
        Arrays.fill(values, start + size, start + i, null);
        size = i + 1;
      }
      values[start + i] = value;
      return value;
    }
    void ensure(int n) {
      if (start + n > values.length) {
        Object[] copy = new Object[Math.max(n, Math.max(8, size * 2))];
        System.arraycopy(values, start, copy, 0, size);
        values = copy;
        start = 0;
      }
    }
    RubyArray push(Object value) {
      ensure(size + 1);
      values[start + size++] = value;
      return this;
    }
    Object pop() {
      if (size == 0)
        return null;
      Object value = values[start + --size];
      values[start + size] = null;
      return value;
    }
    Object shift() {
      if (size == 0)
        return null;
      Object value = values[start];
      values[start++] = null;
      size--;
      return value;
    }
    Object[] copy() {
      return Arrays.copyOfRange(values, start, start + size);
    }
    @Override
    public boolean equals(Object other) {
      return other instanceof RubyArray && Arrays.deepEquals(copy(), ((RubyArray) other).copy());
    }
    @Override
    public int hashCode() {
      return Arrays.deepHashCode(copy());
    }
  }
  public static final class RubyHash extends LinkedHashMap<Object, Object> {
    final boolean keywords;
    RubyHash(boolean keywords) {
      this.keywords = keywords;
    }
    @Override
    public Object put(Object key, Object value) {
      if (key instanceof RubyString)
        key = new RubyString(((RubyString) key).copyBytes(), true, ((RubyString) key).binary);
      super.put(key, value);
      return value;
    }
  }
  public static final class RubyRange {
    final long first, last;
    final boolean exclude;
    RubyRange(long first, long last, boolean exclude) {
      this.first = first;
      this.last = last;
      this.exclude = exclude;
    }
  }
  /** Internal transport for return, break, and next across generated methods. */
  public static final class ControlFlow extends RuntimeException {
    final String kind;
    final Object target;
    final Object value;
    ControlFlow(String kind, Object target, Object value) {
      super(null, null, false, false);
      this.kind = kind;
      this.target = target;
      this.value = value;
    }
  }
  /** Platform-thread implementation; virtual-thread migration remains planned. */
  static final class RubyThread {
    final Thread thread;
    volatile Object value;
    volatile Throwable failure;
    RubyThread(Block block, Object[] args) {
      thread = new Thread(() -> {
        try {
          value = block.call(args);
        } catch (Throwable e) {
          failure = e;
        }
      }, "spinel");
      thread.start();
    }
    Object value() {
      try {
        thread.join();
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new RuntimeException(e);
      }
      if (failure instanceof RuntimeException)
        throw (RuntimeException) failure;
      if (failure != null)
        throw new RuntimeException(failure);
      return value;
    }
  }
  static final class RubyFile implements AutoCloseable {
    final BufferedReader reader;
    final OutputStream out;
    RubyFile(String path, String mode) throws IOException {
      reader = mode.startsWith("r") ? Files.newBufferedReader(Path.of(path), StandardCharsets.UTF_8)
                                    : null;
      out = reader == null ? Files.newOutputStream(Path.of(path), StandardOpenOption.CREATE,
                                 mode.startsWith("a") ? StandardOpenOption.APPEND
                                                      : StandardOpenOption.TRUNCATE_EXISTING)
                           : null;
    }
    public void close() throws IOException {
      if (reader != null)
        reader.close();
      if (out != null)
        out.close();
    }
  }
  public static Environment root(Program program, String[] args, int slots) {
    State state = new State(program);
    for (String name :
        new String[] {"Array", "Hash", "String", "Integer", "Float", "Symbol", "Struct", "Data",
            "Math", "File", "Thread", "Process", "ArgumentError", "RuntimeError"})
      state.constants.put(name, new RubyClass(name, null, null));
    RubyArray argv = new RubyArray(0, null);
    for (String arg : args) argv.push(string(arg, false));
    state.constants.put("ARGV", argv);
    ((RubyClass) state.constants.get("Process"))
        .constants.put("CLOCK_MONOTONIC", symbol("CLOCK_MONOTONIC"));
    state.globals.put("$stdout", System.out);
    state.globals.put("$stderr", System.err);
    return new Environment(state, null, new RubyObject(null), null, slots, null, null);
  }
  public static Object get(Environment env, int depth, int slot) {
    while (depth-- > 0) env = env.parent;
    return env.slots[slot];
  }
  public static Object set(Environment env, int depth, int slot, Object value) {
    while (depth-- > 0) env = env.parent;
    return env.slots[slot] = value;
  }
  public static Object self(Environment env) {
    return env.self;
  }
  public static Object ivar(Environment env, String name) {
    return ((RubyObject) env.self).ivars.get(name);
  }
  public static Object ivarSet(Environment env, String name, Object value) {
    ((RubyObject) env.self).ivars.put(name, value);
    return value;
  }
  public static Object global(Environment env, String name) {
    return env.state.globals.get(name);
  }
  public static Object globalSet(Environment env, String name, Object value) {
    env.state.globals.put(name, value);
    return value;
  }
  public static Object constant(Environment env, String name) {
    for (RubyClass c = env.lexical; c != null; c = c.lexical)
      if (c.constants.containsKey(name))
        return c.constants.get(name);
    if (env.state.constants.containsKey(name))
      return env.state.constants.get(name);
    throw new IllegalArgumentException("NameError: uninitialized constant " + name);
  }
  public static Object constantAt(Object owner, String name) {
    Object value = ((RubyClass) owner).constants.get(name);
    if (value == null)
      throw new IllegalArgumentException(
          "NameError: uninitialized constant " + owner + "::" + name);
    return value;
  }
  public static Object constantSet(Environment env, String name, Object value) {
    if (value instanceof RubyClass && ((RubyClass) value).name.equals("<anonymous>")) {
      // Struct class identity does not depend on its display name.
    }
    if (env.lexical == null)
      env.state.constants.put(name, value);
    else
      env.lexical.constants.put(name, value);
    return value;
  }
  public static Environment classEnv(
      Environment env, String name, Object parent, boolean module, int slots) {
    Map<String, Object> constants =
        env.lexical == null ? env.state.constants : env.lexical.constants;
    Object old = constants.get(name);
    RubyClass klass;
    if (old == null) {
      klass =
          new RubyClass(name, parent instanceof RubyClass ? (RubyClass) parent : null, env.lexical);
      constants.put(name, klass);
    } else if (old instanceof RubyClass)
      klass = (RubyClass) old;
    else
      throw new IllegalArgumentException("TypeError: " + name + " is not a class/module");
    return new Environment(env.state, null, klass, klass, slots, null, null);
  }
  public static Object define(Environment env, String name, int id, int slots, boolean singleton) {
    RubyMethod method = new RubyMethod(id, slots, env.lexical);
    if (env.self instanceof RubyClass)
      (singleton ? ((RubyClass) env.self).singleton : ((RubyClass) env.self).methods)
          .put(name, method);
    else
      env.state.functions.put(name, method);
    return symbol(name);
  }
  public static Object defineClosure(Environment env, String name, int id, int slots) {
    define(env, name, id, slots, false);
    RubyMethod method = env.self instanceof RubyClass ? ((RubyClass) env.self).methods.get(name)
                                                      : env.state.functions.get(name);
    method.captured = env;
    return symbol(name);
  }
  public static Object[] blockArgs(Object[] args) {
    return args.length == 1 && args[0] instanceof RubyArray ? ((RubyArray) args[0]).copy() : args;
  }
  public static void start(Program program, String[] args, int slots) {
    final Throwable[] failure = {null};
    Thread thread = new Thread(null, () -> {
      Environment env = root(program, args, slots);
      try {
        program.invoke(0, env, EMPTY, null);
      } catch (ControlFlow flow) {
        if (!flow.kind.equals("return") || flow.target != env)
          failure[0] = flow;
      } catch (Throwable error) {
        failure[0] = error;
      } finally {
        env.active = false;
      }
    }, "spinel-main", Long.getLong("spinel.stackSize", 64L * 1024 * 1024));
    thread.start();
    try {
      thread.join();
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new RuntimeException(e);
    }
    if (failure[0] instanceof RuntimeException)
      throw (RuntimeException) failure[0];
    if (failure[0] instanceof Error)
      throw (Error) failure[0];
    if (failure[0] != null)
      throw new RuntimeException(failure[0]);
  }
  public static Object arg(Object[] args, int index) {
    return index < args.length ? args[index] : null;
  }
  public static Object keyword(Object[] args, String name) {
    Object last = args.length == 0 ? null : args[args.length - 1];
    if (!(last instanceof RubyHash) || !((RubyHash) last).containsKey(symbol(name)))
      throw new IllegalArgumentException("ArgumentError: missing keyword: " + name);
    return ((RubyHash) last).get(symbol(name));
  }
  public static boolean hasKeyword(Object[] args, String name) {
    return args.length > 0 && args[args.length - 1] instanceof RubyHash
        && ((RubyHash) args[args.length - 1]).containsKey(symbol(name));
  }
  public static int positionalSize(Object[] args) {
    return args.length > 0 && args[args.length - 1] instanceof RubyHash
            && ((RubyHash) args[args.length - 1]).keywords
        ? args.length - 1
        : args.length;
  }
  private static final Map<String, Set<String>> KEYWORD_NAMES = new ConcurrentHashMap<>();
  public static void checkKeywords(Object[] args, String names) {
    if (positionalSize(args) == args.length)
      return;
    Set<String> allowed =
        KEYWORD_NAMES.computeIfAbsent(names, key -> new HashSet<>(Arrays.asList(key.split(","))));
    for (Object key : ((RubyHash) args[args.length - 1]).keySet())
      if (!(key instanceof RubySymbol) || !allowed.contains(((RubySymbol) key).name))
        throw new IllegalArgumentException("ArgumentError: unknown keyword: " + key);
  }
  public static void arity(Object[] args, int required, int optional, boolean keywords) {
    int count = args.length;
    if (keywords && count > 0 && args[count - 1] instanceof RubyHash
        && ((RubyHash) args[count - 1]).keywords)
      count--;
    if (count < required || count > required + optional)
      throw new IllegalArgumentException("ArgumentError: wrong number of arguments (given " + count
          + ", expected " + required + ")");
  }
  public static Block block(Environment captured, int id, int slots) {
    return new Block() {
      public Object call(Object[] args) {
        return callWithSelf(captured.self, args);
      }
      public Object callWithSelf(Object self, Object[] args) {
        Environment env = new Environment(captured.state, captured, self, captured.lexical, slots,
            captured.block, captured.method);
        env.breakTarget = this;
        try {
          return captured.state.program.invoke(id, env, args, null);
        } catch (ControlFlow flow) {
          if (flow.kind.equals("next") && flow.target == env)
            return flow.value;
          throw flow;
        }
      }
    };
  }
  public static Object jump(Environment env, String kind, Object value) {
    if ((kind.equals("return") || kind.equals("break"))
        && (!env.method.active || env.method.owner != Thread.currentThread()))
      throw new IllegalStateException("LocalJumpError: unexpected " + kind);
    Object target = kind.equals("return") ? env.method
        : kind.equals("break")            ? env.breakTarget
                                          : env;
    if (target == null)
      throw new IllegalStateException("LocalJumpError: unexpected " + kind);
    throw new ControlFlow(kind, target, value);
  }
  public static Object yield(Environment env, Object[] args) {
    if (env.block == null)
      throw new IllegalStateException("LocalJumpError: no block given");
    return env.block.call(args);
  }
  static Object invoke(
      Environment caller, Object receiver, RubyMethod method, Object[] args, Block block) {
    Environment env = new Environment(
        caller.state, method.captured, receiver, method.lexical, method.slots, block, null);
    try {
      return caller.state.program.invoke(method.id, env, args, block);
    } catch (ControlFlow flow) {
      if (flow.kind.equals("return") && flow.target == env)
        return flow.value;
      throw flow;
    } finally {
      env.active = false;
    }
  }
  static RubyMethod find(RubyClass klass, String name, boolean singleton) {
    if (klass == null)
      return null;
    RubyMethod method = (singleton ? klass.singleton : klass.methods).get(name);
    if (method != null)
      return method;
    if (!singleton)
      for (int i = klass.includes.size() - 1; i >= 0; i--) {
        method = find(klass.includes.get(i), name, false);
        if (method != null)
          return method;
      }
    return find(klass.parent, name, singleton);
  }
  public static boolean truth(Object value) {
    return value != null && !Boolean.FALSE.equals(value);
  }
  public static Object bool(boolean value) {
    return Boolean.valueOf(value);
  }
  public static Object number(long value) {
    return Long.valueOf(value);
  }
  public static Object real(double value) {
    return Double.valueOf(value);
  }
  public static Object integerLiteral(String value) {
    return narrow(new BigInteger(value));
  }
  public static Object string(String value, boolean frozen) {
    return new RubyString(value.getBytes(StandardCharsets.UTF_8), frozen, false);
  }
  public static Object symbol(String value) {
    return new RubySymbol(value);
  }
  public static Object array(Object[] values) {
    return new RubyArray(values);
  }
  public static Object dict(Object[] pairs, boolean keywords) {
    RubyHash result = new RubyHash(keywords);
    for (int i = 0; i < pairs.length; i += 2) result.put(pairs[i], pairs[i + 1]);
    return result;
  }
  public static Object range(Object first, Object last, boolean exclude) {
    return new RubyRange(integer(first).longValueExact(), integer(last).longValueExact(), exclude);
  }
  public static Object element(Object value, int index) {
    return value instanceof RubyArray ? ((RubyArray) value).get(index) : index == 0 ? value : null;
  }
  static boolean floating(Object value) {
    return value instanceof Double || value instanceof Float;
  }
  static BigInteger integer(Object value) {
    if (value instanceof BigInteger)
      return (BigInteger) value;
    if (value instanceof Number)
      return BigInteger.valueOf(((Number) value).longValue());
    throw new IllegalArgumentException("TypeError: expected Integer, got " + inspect(value));
  }
  static Object narrow(BigInteger value) {
    return value.bitLength() < 64 ? Long.valueOf(value.longValue()) : value;
  }
  static double decimal(Object value) {
    if (!(value instanceof Number))
      throw new IllegalArgumentException("TypeError: expected Numeric");
    return ((Number) value).doubleValue();
  }
  static BigInteger floorDivide(BigInteger a, BigInteger b) {
    BigInteger[] qr = a.divideAndRemainder(b);
    return qr[1].signum() != 0 && a.signum() != b.signum() ? qr[0].subtract(BigInteger.ONE) : qr[0];
  }
  public static Object add(Object a, Object b) {
    if (a instanceof RubyString) {
      RubyString out = new RubyString(((RubyString) a).copyBytes(), false, ((RubyString) a).binary);
      return out.append(str(b));
    }
    if (a instanceof RubyArray && b instanceof RubyArray) {
      RubyArray out = new RubyArray(((RubyArray) a).copy());
      for (Object value : ((RubyArray) b).copy()) out.push(value);
      return out;
    }
    if (floating(a) || floating(b))
      return decimal(a) + decimal(b);
    if (a instanceof Long && b instanceof Long)
      try {
        return Math.addExact((Long) a, (Long) b);
      } catch (ArithmeticException overflow) {
      }
    return narrow(integer(a).add(integer(b)));
  }
  public static Object sub(Object a, Object b) {
    if (floating(a) || floating(b))
      return decimal(a) - decimal(b);
    if (a instanceof Long && b instanceof Long)
      try {
        return Math.subtractExact((Long) a, (Long) b);
      } catch (ArithmeticException overflow) {
      }
    return narrow(integer(a).subtract(integer(b)));
  }
  public static Object mul(Object a, Object b) {
    if (a instanceof RubyString) {
      int n = integer(b).intValueExact();
      if (n < 0)
        throw new IllegalArgumentException("ArgumentError: negative argument");
      RubyString str = (RubyString) a;
      byte[] out = new byte[Math.multiplyExact(str.length, n)];
      for (int i = 0; i < n; i++) System.arraycopy(str.bytes, 0, out, i * str.length, str.length);
      return new RubyString(out, false, str.binary);
    }
    if (floating(a) || floating(b))
      return decimal(a) * decimal(b);
    if (a instanceof Long && b instanceof Long)
      try {
        return Math.multiplyExact((Long) a, (Long) b);
      } catch (ArithmeticException overflow) {
      }
    return narrow(integer(a).multiply(integer(b)));
  }
  public static Object div(Object a, Object b) {
    if (floating(a) || floating(b))
      return decimal(a) / decimal(b);
    long left = a instanceof Long ? (Long) a : 0, right = b instanceof Long ? (Long) b : 0;
    if (a instanceof Long && b instanceof Long && !(left == Long.MIN_VALUE && right == -1))
      return Math.floorDiv(left, right);
    return narrow(floorDivide(integer(a), integer(b)));
  }
  public static Object mod(Object a, Object b) {
    if (floating(a) || floating(b)) {
      double x = decimal(a), y = decimal(b);
      return x - y * Math.floor(x / y);
    }
    if (a instanceof Long && b instanceof Long)
      return Math.floorMod((Long) a, (Long) b);
    BigInteger x = integer(a), y = integer(b);
    return narrow(x.subtract(floorDivide(x, y).multiply(y)));
  }
  public static Object binary(String op, Object a, Object b) {
    switch (op) {
      case "+":
        return add(a, b);
      case "-":
        return sub(a, b);
      case "*":
        return mul(a, b);
      case "/":
        return div(a, b);
      case "%":
        return mod(a, b);
      case "==":
        return equal(a, b);
      case "!=":
        return !equal(a, b);
      case "<":
        return compare(a, b) < 0;
      case "<=":
        return compare(a, b) <= 0;
      case ">":
        return compare(a, b) > 0;
      case ">=":
        return compare(a, b) >= 0;
      case "&":
        return narrow(integer(a).and(integer(b)));
      case "|":
        return narrow(integer(a).or(integer(b)));
      case "^":
        return narrow(integer(a).xor(integer(b)));
      case "<<":
        if (a instanceof RubyString)
          return ((RubyString) a).append(b);
        if (a instanceof RubyArray)
          return ((RubyArray) a).push(b);
        return narrow(integer(a).shiftLeft(integer(b).intValueExact()));
      case ">>":
        return narrow(integer(a).shiftRight(integer(b).intValueExact()));
      case "**":
        if (floating(a) || floating(b) || integer(b).signum() < 0)
          return Math.pow(decimal(a), decimal(b));
        return narrow(integer(a).pow(integer(b).intValueExact()));
      default:
        throw new UnsupportedOperationException("unsupported binary operator " + op);
    }
  }
  public static boolean equal(Object a, Object b) {
    if (a instanceof Number && b instanceof Number) {
      if (floating(a) || floating(b))
        return decimal(a) == decimal(b);
      return integer(a).equals(integer(b));
    }
    if (a instanceof RubyArray && b instanceof RubyArray) {
      RubyArray x = (RubyArray) a, y = (RubyArray) b;
      if (x.size != y.size)
        return false;
      for (int i = 0; i < x.size; i++)
        if (!equal(x.get(i), y.get(i)))
          return false;
      return true;
    }
    if (a instanceof RubyHash && b instanceof RubyHash) {
      RubyHash x = (RubyHash) a, y = (RubyHash) b;
      if (x.size() != y.size())
        return false;
      for (Map.Entry<Object, Object> entry : x.entrySet())
        if (!y.containsKey(entry.getKey()) || !equal(entry.getValue(), y.get(entry.getKey())))
          return false;
      return true;
    }
    return Objects.equals(a, b);
  }
  static int compare(Object a, Object b) {
    if (a instanceof RubyString && b instanceof RubyString)
      return Arrays.compareUnsigned(((RubyString) a).copyBytes(), ((RubyString) b).copyBytes());
    if (floating(a) || floating(b))
      return Double.compare(decimal(a), decimal(b));
    return integer(a).compareTo(integer(b));
  }
  static RubyString str(Object value) {
    if (value instanceof RubyString)
      return (RubyString) value;
    throw new IllegalArgumentException("TypeError: expected String, got " + inspect(value));
  }
  public static Object interpolate(Object[] parts) {
    RubyString out = new RubyString(new byte[0], false, false);
    for (Object part : parts) out.append(string(text(part), false));
    return out;
  }
  static String text(Object value) {
    if (value == null)
      return "";
    if (value instanceof RubyArray || value instanceof RubyHash)
      return inspect(value);
    return value.toString();
  }
  static String inspect(Object value) {
    if (value == null)
      return "nil";
    if (value instanceof RubyString)
      return "\""
          + value.toString()
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\t", "\\t")
          + "\"";
    if (value instanceof RubySymbol)
      return ":" + value;
    if (value instanceof RubyArray) {
      StringJoiner join = new StringJoiner(", ", "[", "]");
      for (Object item : ((RubyArray) value).copy()) join.add(inspect(item));
      return join.toString();
    }
    if (value instanceof RubyHash) {
      StringJoiner join = new StringJoiner(", ", "{", "}");
      ((RubyHash) value).forEach((key, item) -> join.add(inspect(key) + "=>" + inspect(item)));
      return join.toString();
    }
    return text(value);
  }
  static void output(OutputStream out, Object value, boolean newline) {
    try {
      if (newline && value instanceof RubyArray) {
        for (Object item : ((RubyArray) value).copy()) output(out, item, true);
        return;
      }
      byte[] bytes = value instanceof RubyString ? ((RubyString) value).copyBytes()
                                                 : text(value).getBytes(StandardCharsets.UTF_8);
      out.write(bytes);
      if (newline && (bytes.length == 0 || bytes[bytes.length - 1] != '\n'))
        out.write('\n');
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }
  static Object attribute(RubyClass klass, RubyObject obj, String name, Object[] args) {
    for (RubyClass c = klass; c != null; c = c.parent) {
      if (args.length == 0 && c.readers.contains(name))
        return obj.ivars.get("@" + name);
      if (args.length == 1 && name.endsWith("=")
          && c.writers.contains(name.substring(0, name.length() - 1))) {
        obj.ivars.put("@" + name.substring(0, name.length() - 1), args[0]);
        return args[0];
      }
    }
    return MISSING;
  }
  static final Object MISSING = new Object();
  public static Object call(
      Environment env, Object receiver, String name, Object[] args, Block block) {
    try {
      return dispatch(env, receiver, name, args, block);
    } catch (ControlFlow flow) {
      if (block != null && flow.kind.equals("break") && flow.target == block)
        return flow.value;
      throw flow;
    }
  }
  static Object dispatch(
      Environment env, Object receiver, String name, Object[] args, Block block) {
    if (receiver instanceof RubyClass) {
      RubyClass klass = (RubyClass) receiver;
      RubyMethod method = find(klass, name, true);
      if (method != null)
        return invoke(env, receiver, method, args, block);
      return classCall(env, klass, name, args, block);
    }
    if (receiver instanceof RubyObject) {
      RubyObject obj = (RubyObject) receiver;
      RubyMethod method = find(obj.klass, name, false);
      if (method != null)
        return invoke(env, receiver, method, args, block);
      Object value = attribute(obj.klass, obj, name, args);
      if (value != MISSING)
        return value;
      method = env.state.functions.get(name);
      if (method != null && receiver == env.self)
        return invoke(env, receiver, method, args, block);
    }
    if (name.equals("nil?"))
      return receiver == null;
    if (name.equals("!"))
      return !truth(receiver);
    if (name.equals("is_a?") || name.equals("kind_of?"))
      return isA(receiver, args[0]);
    if (name.equals("==") || name.equals("!=") || name.equals("===") || name.equals("<")
        || name.equals("<=") || name.equals(">") || name.equals(">="))
      return name.equals("===") ? isCase(receiver, args[0]) : binary(name, receiver, args[0]);
    if (name.equals("to_s"))
      return receiver instanceof RubyString ? receiver : string(text(receiver), false);
    if (name.equals("inspect"))
      return string(inspect(receiver), false);
    if (receiver instanceof Number)
      return numericCall(receiver, name, args, block);
    if (receiver instanceof RubyString)
      return stringCall((RubyString) receiver, name, args, block);
    if (receiver instanceof RubyArray)
      return arrayCall((RubyArray) receiver, name, args, block);
    if (receiver instanceof RubyHash)
      return hashCall((RubyHash) receiver, name, args, block);
    if (receiver instanceof RubyRange)
      return rangeCall((RubyRange) receiver, name, args, block);
    if (receiver instanceof RubyThread && name.equals("value"))
      return ((RubyThread) receiver).value();
    if (receiver instanceof RubyThread && name.equals("join")) {
      ((RubyThread) receiver).value();
      return receiver;
    }
    if (receiver instanceof RubyFile && name.equals("each_line")) {
      try {
        StringBuilder line = new StringBuilder();
        int c;
        while ((c = ((RubyFile) receiver).reader.read()) != -1) {
          line.append((char) c);
          if (c == '\n') {
            block.call(new Object[] {string(line.toString(), false)});
            line.setLength(0);
          }
        }
        if (line.length() > 0)
          block.call(new Object[] {string(line.toString(), false)});
        return receiver;
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    }
    if (receiver instanceof RubyFile && (name.equals("write") || name.equals("print"))) {
      long count = 0;
      for (Object value : args) {
        byte[] bytes = value instanceof RubyString ? ((RubyString) value).copyBytes()
                                                   : text(value).getBytes(StandardCharsets.UTF_8);
        output(((RubyFile) receiver).out, value, false);
        count += bytes.length;
      }
      return name.equals("write") ? count : null;
    }
    if (receiver instanceof RubyFile && name.equals("puts")) {
      for (Object value : args) output(((RubyFile) receiver).out, value, true);
      return null;
    }
    if (receiver instanceof PrintStream && name.equals("puts")) {
      for (Object value : args) output((PrintStream) receiver, value, true);
      return null;
    }
    if (receiver == env.self)
      return kernel(env, name, args, block);
    throw new UnsupportedOperationException("NoMethodError: " + name + " for " + inspect(receiver));
  }
  public static Object bare(Environment env, String name, Object[] args, Block block) {
    try {
      return bareDispatch(env, name, args, block);
    } catch (ControlFlow flow) {
      if (block != null && flow.kind.equals("break") && flow.target == block)
        return flow.value;
      throw flow;
    }
  }
  static Object bareDispatch(Environment env, String name, Object[] args, Block block) {
    if (env.self instanceof RubyClass) {
      RubyMethod method = find((RubyClass) env.self, name, true);
      if (method != null)
        return invoke(env, env.self, method, args, block);
    } else if (env.self instanceof RubyObject) {
      RubyMethod method = find(((RubyObject) env.self).klass, name, false);
      if (method != null)
        return invoke(env, env.self, method, args, block);
      Object value = attribute(((RubyObject) env.self).klass, (RubyObject) env.self, name, args);
      if (value != MISSING)
        return value;
    }
    RubyMethod method = env.state.functions.get(name);
    if (method != null)
      return invoke(env, env.self, method, args, block);
    return kernel(env, name, args, block);
  }
  static Object kernel(Environment env, String name, Object[] args, Block block) {
    switch (name) {
      case "puts":
        if (args.length == 0)
          output(System.out, null, true);
        for (Object value : args) output(System.out, value, true);
        return null;
      case "print":
        for (Object value : args) output(System.out, value, false);
        return null;
      case "p":
        for (Object value : args) output(System.out, string(inspect(value), false), true);
        return args.length == 1 ? args[0] : array(args);
      case "putc": {
        Object value = args[0];
        byte[] bytes = value instanceof Number ? new byte[] {(byte) integer(value).intValue()}
                                               : str(value).copyBytes();
        System.out.write(bytes[0]);
        return value;
      }
      case "printf": {
        String format = str(args[0]).toString();
        Object[] values = Arrays.copyOfRange(args, 1, args.length);
        for (int i = 0; i < values.length; i++)
          if (values[i] instanceof RubyString)
            values[i] = values[i].toString();
        output(System.out, string(String.format(Locale.ROOT, format, values), false), false);
        return null;
      }
      case "Integer":
        if (args[0] instanceof Number)
          return narrow(integer(args[0]));
        return narrow(new BigInteger(str(args[0]).toString().trim().replace("_", "")));
      case "Float":
        return decimal(args[0]);
      case "attr_reader":
      case "attr_writer":
      case "attr_accessor": {
        RubyClass klass = (RubyClass) env.self;
        for (Object arg : args) {
          if (!name.equals("attr_writer"))
            klass.readers.add(arg.toString());
          if (!name.equals("attr_reader"))
            klass.writers.add(arg.toString());
        }
        return null;
      }
      case "include":
        for (Object arg : args) ((RubyClass) env.self).includes.add((RubyClass) arg);
        return env.self;
      case "raise":
        throw new IllegalArgumentException(
            (args.length > 1 ? args[0] + ": " : "RuntimeError: ") + text(args[args.length - 1]));
      default:
        throw new UnsupportedOperationException("NoMethodError: " + name);
    }
  }
  static Object classCall(
      Environment env, RubyClass klass, String name, Object[] args, Block block) {
    if (klass.name.equals("Math")) {
      double x = decimal(args[0]);
      switch (name) {
        case "sqrt":
          return Math.sqrt(x);
        case "sin":
          return Math.sin(x);
        case "cos":
          return Math.cos(x);
        case "log":
          return Math.log(x);
        case "exp":
          return Math.exp(x);
        default:
          break;
      }
    }
    if (klass.name.equals("Process") && name.equals("clock_gettime"))
      return System.nanoTime() / 1.0e9;
    if (klass.name.equals("Thread")) {
      if (name.equals("pass")) {
        Thread.yield();
        return null;
      }
      if (name.equals("new"))
        return new RubyThread(block, args);
    }
    if (klass.name.equals("File")) {
      try {
        if (name.equals("delete")) {
          for (Object arg : args) Files.delete(Path.of(str(arg).toString()));
          return (long) args.length;
        }
        if (name.equals("open")) {
          RubyFile file = new RubyFile(
              str(args[0]).toString(), args.length > 1 ? str(args[1]).toString() : "r");
          if (block == null)
            return file;
          try (file) {
            return block.call(new Object[] {file});
          }
        }
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    }
    if ((klass.name.equals("Struct") && name.equals("new"))
        || (klass.name.equals("Data") && name.equals("define"))) {
      RubyClass result = new RubyClass("<anonymous>", null, env.lexical);
      result.members = Arrays.stream(args).map(Object::toString).toArray(String[] ::new);
      result.data = klass.name.equals("Data");
      for (String member : result.members) {
        result.readers.add(member);
        if (!result.data)
          result.writers.add(member);
      }
      if (block != null)
        block.callWithSelf(result, new Object[] {result});
      return result;
    }
    if (name.equals("new")) {
      switch (klass.name) {
        case "Array": {
          if (args.length == 0)
            return new RubyArray(0, null);
          if (args[0] instanceof RubyArray)
            return new RubyArray(((RubyArray) args[0]).copy());
          int size = integer(args[0]).intValueExact();
          RubyArray result = new RubyArray(size, args.length > 1 ? args[1] : null);
          if (block != null)
            for (int i = 0; i < size; i++) result.set(i, block.call(new Object[] {(long) i}));
          return result;
        }
        case "Hash":
          return new RubyHash(false);
        case "String":
          return new RubyString(
              args.length == 0 ? new byte[0] : str(args[0]).copyBytes(), false, false);
        default: {
          RubyObject result = new RubyObject(klass);
          if (klass.members != null) {
            if (args.length != klass.members.length)
              throw new IllegalArgumentException("ArgumentError: struct arity");
            for (int i = 0; i < args.length; i++) result.ivars.put("@" + klass.members[i], args[i]);
          } else {
            RubyMethod method = find(klass, "initialize", false);
            if (method != null)
              invoke(env, result, method, args, block);
            else if (args.length != 0)
              throw new IllegalArgumentException("ArgumentError: wrong constructor arity");
          }
          return result;
        }
      }
    }
    if (name.equals("==="))
      return isA(args[0], klass);
    throw new UnsupportedOperationException("NoMethodError: " + klass.name + "." + name);
  }
  static Object numericCall(Object value, String name, Object[] args, Block block) {
    switch (name) {
      case "+@":
        return value;
      case "-@":
        return sub(0L, value);
      case "~":
        return narrow(integer(value).not());
      case "to_i":
        return narrow(integer(value));
      case "to_f":
        return decimal(value);
      case "succ":
        return add(value, 1L);
      case "chr": {
        int c = integer(value).intValueExact();
        if (c < 0 || c > 255)
          throw new IllegalArgumentException("RangeError: invalid codepoint");
        return new RubyString(new byte[] {(byte) c}, false, c > 127);
      }
      case "round": {
        int digits = args.length == 0 ? 0 : integer(args[0]).intValueExact();
        BigDecimal rounded =
            BigDecimal.valueOf(decimal(value)).setScale(digits, RoundingMode.HALF_UP);
        return digits <= 0 ? narrow(rounded.toBigInteger()) : rounded.doubleValue();
      }
      case "times":
        for (long i = 0, n = integer(value).longValueExact(); i < n; i++)
          block.call(new Object[] {i});
        return value;
      default:
        if (args.length == 1)
          return binary(name, value, args[0]);
        throw new UnsupportedOperationException("NoMethodError: Numeric#" + name);
    }
  }
  static Object stringCall(RubyString value, String name, Object[] args, Block block) {
    switch (name) {
      case "+":
      case "*":
      case "<<":
        return binary(name, value, args[0]);
      case "+@":
        return value.frozen ? new RubyString(value.copyBytes(), false, value.binary) : value;
      case "dup":
        return new RubyString(value.copyBytes(), false, value.binary);
      case "length":
      case "size":
        return (long) (value.binary
                ? value.length
                : value.toString().codePointCount(0, value.toString().length()));
      case "bytesize":
        return (long) value.length;
      case "empty?":
        return value.length == 0;
      case "getbyte": {
        int i = integer(args[0]).intValueExact();
        if (i < 0)
          i += value.length;
        return i < 0 || i >= value.length ? null : (long) (value.bytes[i] & 255);
      }
      case "setbyte": {
        value.mutable();
        int i = integer(args[0]).intValueExact();
        if (i < 0)
          i += value.length;
        if (i < 0 || i >= value.length)
          throw new IndexOutOfBoundsException("IndexError");
        value.bytes[i] = (byte) integer(args[1]).intValue();
        return args[1];
      }
      case "bytes": {
        RubyArray result = new RubyArray(0, null);
        for (int i = 0; i < value.length; i++) result.push((long) (value.bytes[i] & 255));
        return result;
      }
      case "sum": {
        int bits = args.length == 0 ? 16 : integer(args[0]).intValueExact();
        BigInteger total = BigInteger.ZERO;
        for (int i = 0; i < value.length; i++)
          total = total.add(BigInteger.valueOf(value.bytes[i] & 255));
        if (bits > 0)
          total = total.and(BigInteger.ONE.shiftLeft(bits).subtract(BigInteger.ONE));
        return narrow(total);
      }
      case "[]":
      case "byteslice": {
        boolean bytes = name.equals("byteslice") || value.binary;
        int length =
            bytes ? value.length : value.toString().codePointCount(0, value.toString().length());
        int start = integer(args[0]).intValueExact();
        if (start < 0)
          start += length;
        int count = args.length > 1 ? integer(args[1]).intValueExact() : 1;
        if (start < 0 || start > length || count < 0 || (start == length && args.length == 1))
          return null;
        count = Math.min(count, length - start);
        if (bytes)
          return new RubyString(
              Arrays.copyOfRange(value.bytes, start, start + count), false, value.binary);
        String text = value.toString();
        int from = text.offsetByCodePoints(0, start), to = text.offsetByCodePoints(from, count);
        return string(text.substring(from, to), false);
      }
      case "strip":
        return string(value.toString().strip(), false);
      case "split": {
        String text = value.toString(),
               separator = args.length == 0 ? " " : str(args[0]).toString();
        String[] parts = separator.equals(" ")
            ? (text.strip().isEmpty() ? new String[0] : text.strip().split("\\s+"))
            : text.split(java.util.regex.Pattern.quote(separator), -1);
        RubyArray result = new RubyArray(0, null);
        int n = parts.length;
        if (!separator.equals(" "))
          while (n > 0 && parts[n - 1].isEmpty()) n--;
        for (int i = 0; i < n; i++) result.push(string(parts[i], false));
        return result;
      }
      case "index": {
        int index = value.toString().indexOf(str(args[0]).toString());
        return index < 0 ? null : (long) value.toString().codePointCount(0, index);
      }
      case "to_i": {
        java.util.regex.Matcher matcher =
            java.util.regex.Pattern.compile("^[\\s]*([+-]?[0-9][0-9_]*)").matcher(value.toString());
        return matcher.find() ? narrow(new BigInteger(matcher.group(1).replace("_", ""))) : 0L;
      }
      default:
        throw new UnsupportedOperationException("NoMethodError: String#" + name);
    }
  }
  static Object arrayCall(RubyArray value, String name, Object[] args, Block block) {
    switch (name) {
      case "[]":
        return value.get(integer(args[0]).longValueExact());
      case "[]=":
        return value.set(integer(args[0]).longValueExact(), args[1]);
      case "push":
        for (Object arg : args) value.push(arg);
        return value;
      case "<<":
        return value.push(args[0]);
      case "pop":
        return value.pop();
      case "shift":
        return value.shift();
      case "length":
      case "size":
        return (long) value.size;
      case "empty?":
        return value.size == 0;
      case "dup":
        return new RubyArray(value.copy());
      case "reverse!":
        for (int i = 0, j = value.size - 1; i < j; i++, j--) {
          Object old = value.get(i);
          value.set(i, value.get(j));
          value.set(j, old);
        }
        return value;
      case "each":
        for (int i = 0; i < value.size; i++) block.call(new Object[] {value.get(i)});
        return value;
      case "each_with_index":
        for (int i = 0; i < value.size; i++) block.call(new Object[] {value.get(i), (long) i});
        return value;
      case "map": {
        RubyArray out = new RubyArray(0, null);
        for (int i = 0; i < value.size; i++) out.push(block.call(new Object[] {value.get(i)}));
        return out;
      }
      case "sum": {
        Object sum = args.length == 0 ? 0L : args[0];
        for (int i = 0; i < value.size; i++) {
          Object item = value.get(i);
          sum = add(sum, block == null ? item : block.call(new Object[] {item}));
        }
        return sum;
      }
      case "count": {
        long count = 0;
        for (int i = 0; i < value.size; i++) {
          Object item = value.get(i);
          if (block != null ? truth(block.call(new Object[] {item}))
                            : args.length == 0 || equal(item, args[0]))
            count++;
        }
        return count;
      }
      case "sort_by": {
        Object[][] pairs = new Object[value.size][2];
        for (int i = 0; i < value.size; i++) {
          pairs[i][0] = block.call(new Object[] {value.get(i)});
          pairs[i][1] = value.get(i);
        }
        Arrays.sort(pairs, (a, b) -> compare(a[0], b[0]));
        RubyArray out = new RubyArray(0, null);
        for (Object[] pair : pairs) out.push(pair[1]);
        return out;
      }
      default:
        throw new UnsupportedOperationException("NoMethodError: Array#" + name);
    }
  }
  static Object hashCall(RubyHash value, String name, Object[] args, Block block) {
    switch (name) {
      case "[]":
        return value.get(args[0]);
      case "[]=":
        return value.put(args[0], args[1]);
      case "key?":
      case "has_key?":
        return value.containsKey(args[0]);
      case "length":
      case "size":
        return (long) value.size();
      case "empty?":
        return value.isEmpty();
      case "keys":
        return new RubyArray(value.keySet().toArray());
      case "each":
        for (Map.Entry<Object, Object> pair : value.entrySet())
          block.call(new Object[] {new RubyArray(new Object[] {pair.getKey(), pair.getValue()})});
        return value;
      default:
        throw new UnsupportedOperationException("NoMethodError: Hash#" + name);
    }
  }
  static Object rangeCall(RubyRange value, String name, Object[] args, Block block) {
    RubyArray out = name.equals("map") || name.equals("to_a") ? new RubyArray(0, null) : null;
    long count = 0;
    Object sum = 0L;
    for (long i = value.first; value.exclude ? i < value.last : i <= value.last; i++) {
      Object item = name.equals("to_a") ? i : block.call(new Object[] {i});
      switch (name) {
        case "map":
        case "to_a":
          out.push(item);
          break;
        case "each":
          break;
        case "count":
          if (truth(item))
            count++;
          break;
        case "sum":
          sum = add(sum, item);
          break;
        default:
          throw new UnsupportedOperationException("Range#" + name);
      }
      if (i == Long.MAX_VALUE)
        break;
    }
    return out != null ? out : name.equals("count") ? count : name.equals("sum") ? sum : value;
  }
  public static boolean isCase(Object pattern, Object value) {
    return pattern instanceof RubyClass ? isA(value, pattern) : equal(pattern, value);
  }
  static boolean isA(Object value, Object type) {
    if (!(type instanceof RubyClass))
      throw new IllegalArgumentException("TypeError: class or module required");
    RubyClass klass = (RubyClass) type;
    if (value instanceof RubyObject)
      for (RubyClass c = ((RubyObject) value).klass; c != null; c = c.parent)
        if (c == klass || c.includes.contains(klass))
          return true;
    switch (klass.name) {
      case "Integer":
        return value instanceof Long || value instanceof BigInteger;
      case "Float":
        return floating(value);
      case "String":
        return value instanceof RubyString;
      case "Symbol":
        return value instanceof RubySymbol;
      case "Array":
        return value instanceof RubyArray;
      case "Hash":
        return value instanceof RubyHash;
      default:
        return false;
    }
  }
}
