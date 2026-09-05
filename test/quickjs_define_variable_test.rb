# frozen_string_literal: true

require "test_helper"
require "timeout"

describe "VM#define_const / #define_let / #define_var" do
  before do
    @vm = Quickjs::VM.new
  end

  after do
    @vm.dispose!
  end

  describe "binding forms" do
    it "exposes a const to later eval_code" do
      @vm.define_const(:user, {name: "Itadori"})

      _(@vm.eval_code("user.name")).must_equal "Itadori"
    end

    it "makes a const read-only for JS" do
      @vm.define_const(:user, 1)

      _ { @vm.eval_code("user = 2;") }.must_raise Quickjs::TypeError
    end

    it "makes a const collide loudly with a redeclaration in user code" do
      @vm.define_const(:user, 1)

      _ { @vm.eval_code("let user = 2;") }.must_raise Quickjs::SyntaxError
    end

    it "lets JS reassign a let" do
      @vm.define_let(:counter, 1)

      _(@vm.eval_code("counter = 2; counter")).must_equal 2
    end

    it "keeps a let off globalThis" do
      @vm.define_let(:counter, 1)

      _(@vm.eval_code("typeof globalThis.counter")).must_equal "undefined"
    end

    it "puts a var on globalThis" do
      @vm.define_var(:APP_CONFIG, {retries: 3})

      _(@vm.eval_code("globalThis.APP_CONFIG.retries")).must_equal 3
    end
  end

  describe "redefinition" do
    it "refuses to redefine a const" do
      @vm.define_const(:user, 1)

      error = _ { @vm.define_const(:user, 2) }.must_raise ArgumentError
      _(error.message).must_match(/already defined as a const/)
      _(@vm.eval_code("user")).must_equal 1
    end

    it "assigns when a let is defined again" do
      @vm.define_let(:counter, 1)
      @vm.define_let(:counter, 2)

      _(@vm.eval_code("counter")).must_equal 2
    end

    it "assigns when a var is defined again" do
      @vm.define_var(:config, {a: 1})
      @vm.define_var(:config, {a: 2})

      _(@vm.eval_code("globalThis.config.a")).must_equal 2
    end

    it "refuses to change the binding form of an existing name" do
      @vm.define_let(:counter, 1)

      error = _ { @vm.define_var(:counter, 2) }.must_raise ArgumentError
      _(error.message).must_match(/already defined as a let/)
    end
  end

  describe "name validation" do
    it "accepts a String as well as a Symbol" do
      @vm.define_const("user", 1)

      _(@vm.eval_code("user")).must_equal 1
    end

    it "returns the name as a Symbol" do
      _(@vm.define_const("user", 1)).must_equal :user
    end

    it "rejects a name that is not a String or Symbol" do
      _ { @vm.define_const(1, 2) }.must_raise TypeError
    end

    it "rejects a name that is not a valid identifier" do
      error = _ { @vm.define_const("a-b", 1) }.must_raise ArgumentError
      _(error.message).must_match(/not a valid JavaScript identifier/)
    end

    it "rejects a reserved word" do
      error = _ { @vm.define_const("class", 1) }.must_raise ArgumentError
      _(error.message).must_match(/reserved word/)
    end

    it "refuses to let a name smuggle in JavaScript" do
      _ {
        @vm.define_const("x = 1; globalThis.pwned = 1; //", 2)
      }.must_raise ArgumentError

      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
    end

    # The name is the one thing interpolated into the source, so the check on
    # it has to hold against an object that answers for itself. Passing the
    # pattern with to_s and then handing a different name to to_sym is the
    # same escape the value path had, one method along.
    it "refuses a name that answers the pattern and the interpolation differently" do
      bomb = Class.new(String) do
        def to_s = self
        def to_sym = :"ok = 1; globalThis.pwned = 1; var zz"
      end

      key = @vm.define_const(bomb.new("ok"), 1)

      _(key).must_equal :ok
      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
      _(@vm.eval_code("ok")).must_equal 1
    end

    # Validating a copy of the bytes and then handing back a Symbol put a
    # dispatch back between the check and the source, because interpolating a
    # Symbol calls Symbol#to_s. The validated String is what reaches the
    # interpolation now, and to_sym runs only on the way out.
    it "interpolates the bytes it validated, not a name derived again" do
      ::Symbol.class_eval do
        alias_method :_orig_to_s, :to_s
        def to_s = _orig_to_s == "safe" ? "safe = 0; globalThis.pwned = 1; var zz" : _orig_to_s
      end

      begin
        @vm.define_const("safe", 42)
      ensure
        ::Symbol.class_eval { remove_method(:to_s); alias_method :to_s, :_orig_to_s; remove_method :_orig_to_s }
      end

      _(@vm.eval_code("safe")).must_equal 42
      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
    end

    # The binding keyword is interpolated beside the name, and it was a Symbol
    # too. Being ours rather than the caller's is not the property that keeps
    # it out of trouble.
    it "interpolates the keyword as a String as well as the name" do
      ::Symbol.class_eval do
        alias_method :_orig_to_s, :to_s
        def to_s = _orig_to_s == "const" ? "var q = 0; globalThis.pwned = 1; const" : _orig_to_s
      end

      begin
        @vm.define_const(:ok, 1)
      ensure
        ::Symbol.class_eval { remove_method(:to_s); alias_method :to_s, :_orig_to_s; remove_method :_orig_to_s }
      end

      _(@vm.eval_code("ok")).must_equal 1
      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
    end
    # The other half of the same pair: to_sym runs after the declaration, so a
    # patched one decides what the caller is handed back and nothing else.
    it "keeps a patched String#to_sym out of the source and the registry" do
      ::String.class_eval do
        alias_method :_orig_to_sym, :to_sym
        def to_sym = _orig_to_sym == :safe ? :"safe = 0; globalThis.pwned = 1; var zz" : _orig_to_sym
      end

      begin
        @vm.define_const(:safe, 42)
      ensure
        ::String.class_eval { remove_method(:to_sym); alias_method :to_sym, :_orig_to_sym; remove_method :_orig_to_sym }
      end

      _(@vm.eval_code("safe")).must_equal 42
      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
      _ { @vm.define_const(:safe, 99) }.must_raise ArgumentError
    end
    # The value path copies a String subclass rather than calling to_s on it.
    # The name path was still asking, so the class author picked the identifier
    # and the caller's own bytes were never used.
    it "uses a String name's own bytes rather than what it says they are" do
      sub = Class.new(String) { def to_s = "HIJACKED" }

      key = @vm.define_let(sub.new("nm"), 1)

      _(key).must_equal :nm
      _(@vm.eval_code("nm")).must_equal 1
      _(@vm.eval_code("typeof HIJACKED")).must_equal "undefined"
    end
    it "refuses a name from an object that only claims to be a String" do
      liar = Object.new
      def liar.is_a?(_) = true
      def liar.kind_of?(_) = true
      def liar.to_s = "ok"
      def liar.to_sym = :"ok = 1; globalThis.pwned = 1; var zz"

      _ { @vm.define_const(liar, 1) }.must_raise TypeError

      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
    end
      it "refuses a name with anything after the identifier" do
      # \z rather than \Z: the pattern is the whole security story for names,
      # and \Z would let a trailing newline through.
      _ { @vm.define_const("x\n", 1) }.must_raise ArgumentError
      _ { @vm.define_const("x\ny", 1) }.must_raise ArgumentError
    end
  it "allows $ and _ as identifier characters" do
      @vm.define_const(:$_x1, 1)

      _(@vm.eval_code("$_x1")).must_equal 1
    end
  end

  describe "value conversion" do
    it "converts primitives" do
      @vm.define_const(:values, [nil, true, false, 1, 1.5, "s"])

      _(@vm.eval_code("JSON.stringify(values)")).must_equal '[null,true,false,1,1.5,"s"]'
    end

    it "converts nested structures" do
      @vm.define_const(:user, {name: "Itadori", tags: ["strong", "kind"]})

      _(@vm.eval_code("user.name + ': ' + user.tags.join(', ')")).must_equal "Itadori: strong, kind"
    end

    it "converts symbol values to strings" do
      @vm.define_const(:role, :admin)

      _(@vm.eval_code("role")).must_equal "admin"
    end

    it "converts Quickjs::Value::UNDEFINED" do
      @vm.define_const(:nothing, Quickjs::Value::UNDEFINED)

      _(@vm.eval_code("typeof nothing")).must_equal "undefined"
    end

    it "converts Quickjs::Value::NAN" do
      @vm.define_const(:notnum, Quickjs::Value::NAN)

      _(@vm.eval_code("Number.isNaN(notnum)")).must_equal true
    end

    it "converts non-finite floats" do
      @vm.define_const(:inf, Float::INFINITY)
      @vm.define_const(:neg, -Float::INFINITY)
      @vm.define_const(:nan, Float::NAN)

      _(@vm.eval_code("[inf, neg, Number.isNaN(nan)]")).must_equal [Float::INFINITY, -Float::INFINITY, true]
    end

    it "converts integer object keys" do
      @vm.define_const(:by_id, {1 => "one"})

      _(@vm.eval_code("by_id['1']")).must_equal "one"
    end

    it "escapes strings rather than splicing them" do
      @vm.define_const(:sneaky, '"; globalThis.pwned = 1; //')

      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
      _(@vm.eval_code("sneaky")).must_equal '"; globalThis.pwned = 1; //'
    end

    it "raises on a value it cannot represent" do
      error = _ { @vm.define_const(:at, Time.now) }.must_raise TypeError
      _(error.message).must_match(/cannot be converted/)
    end

    it "raises on an unrepresentable value nested in a structure" do
      _ { @vm.define_const(:wrapper, {at: Time.now}) }.must_raise TypeError
    end

    it "raises on an unusable object key" do
      _ { @vm.define_const(:bad, {[1] => "x"}) }.must_raise TypeError
    end

    it "raises on a circular structure" do
      circular = {}
      circular[:self] = circular

      error = _ { @vm.define_const(:loop, circular) }.must_raise ArgumentError
      _(error.message).must_match(/circular/)
    end

    it "allows the same object to appear twice without calling it circular" do
      shared = {n: 1}
      @vm.define_const(:pair, [shared, shared])

      _(@vm.eval_code("pair[0].n + pair[1].n")).must_equal 2
    end
  end

  describe "interaction with eval_code" do
    it "leaves the caller's line numbers untouched" do
      @vm.define_const(:cfg, 1)

      error = _ {
        @vm.eval_code("\nthrow new Error('boom');", filename: "app.js")
      }.must_raise Quickjs::RuntimeError

      _(error.backtrace.first).must_match(/app\.js:2/)
    end

    it "is visible to a function defined with define_function" do
      @vm.define_const(:factor, 3)
      @vm.define_function("scale") { |n| n }

      _(@vm.eval_code("scale(2) * factor")).must_equal 6
    end
  end

  # Injecting configuration and then importing a module that reads it is the
  # obvious pairing, and a declaration reaching module scope isn't obvious
  # from either feature on its own: a module has its own scope, and only
  # `var` lands on `globalThis`.
  describe "interaction with modules" do
    it "exposes a const to an imported module" do
      @vm.define_const(:injected, "from-ruby")
      @vm.import(["read"], from: Quickjs.compile_module("export const read = () => injected;"))

      _(@vm.eval_code("read()")).must_equal "from-ruby"
    end

    it "exposes a var to an imported module through globalThis" do
      @vm.define_var(:injectedVar, "from-ruby-var")
      @vm.import(["read"], from: Quickjs.compile_module("export const read = () => globalThis.injectedVar;"))

      _(@vm.eval_code("read()")).must_equal "from-ruby-var"
    end

    # The module body evaluates at import time, before this name exists, so
    # this only works because the binding is resolved when `read` is called.
    it "exposes a const defined after the module was imported" do
      @vm.import(["read"], from: Quickjs.compile_module("export const read = () => later;"))
      @vm.define_const(:later, "defined-after")

      _(@vm.eval_code("read()")).must_equal "defined-after"
    end

    it "is visible to a Runnable executed on the same VM" do
      @vm.define_const(:fromRuby, "visible")
      Quickjs.compile("globalThis.seen = fromRuby;").run(on: @vm)

      _(@vm.eval_code("seen")).must_equal "visible"
    end
  end
end

describe "define_var onto a global that is already there" do
  # var is the only form that lands on globalThis, so it is the only one an
  # existing property can intercept. Both of these used to report success:
  # the accessor took the value in its setter and handed JS back whatever
  # its getter liked, and the non-writable property discarded the
  # assignment silently, because a declaration eval is sloppy mode.
  it "refuses a global that is an accessor, without handing it the value" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      Object.defineProperty(globalThis, 'CONFIG', {
        configurable: true,
        set(v) { globalThis.captured = JSON.stringify(v); },
        get() { return 'guest'; }
      });
    JS

    err = _ { vm.define_var(:CONFIG, { secret: 'value' }) }.must_raise ArgumentError

    _(err.message).must_match(/accessor/)
    _(vm.eval_code('globalThis.captured')).must_equal Quickjs::Value::UNDEFINED
  end

  it "refuses a global that is not writable" do
    vm = Quickjs::VM.new
    vm.eval_code("Object.defineProperty(globalThis, 'LOCKED', { value: 'theirs', writable: false });")

    err = _ { vm.define_var(:LOCKED, 'mine') }.must_raise ArgumentError

    _(err.message).must_match(/not writable/)
    _(vm.eval_code('globalThis.LOCKED')).must_equal 'theirs'
  end

  it "still defines over an ordinary global" do
    vm = Quickjs::VM.new
    vm.eval_code('globalThis.plain = 1;')

    _(vm.define_var(:plain, 42)).must_equal :plain
    _(vm.eval_code('plain')).must_equal 42
  end

  # Neither lexical form touches globalThis, so an accessor there cannot see
  # the value or change what the name resolves to.
  it "leaves const and let alone" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      Object.defineProperty(globalThis, 'K', {
        configurable: true, set(v) { globalThis.seen = true; }, get() { return 'guest'; }
      });
    JS

    vm.define_const(:K, 'mine')

    _(vm.eval_code('K')).must_equal 'mine'
    _(vm.eval_code('globalThis.seen')).must_equal Quickjs::Value::UNDEFINED
  end
end

describe "a value that expands past what the VM could hold" do
  # A structure reaching the same object twice is written out twice, so each
  # level referencing the level below twice doubles the output. Twenty-five
  # of those is a third of a gigabyte from a handful of Ruby objects, which
  # YAML aliases and Marshal round-trips produce without anyone meaning to.
  def doubling(levels)
    (1..levels).reduce({ n: 1 }) { |inner, _| [inner, inner] }
  end

  it "refuses it, naming the limit it would not fit in" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    err = _ { vm.define_const(:big, doubling(25)) }.must_raise ArgumentError

    _(err.message).must_match(/memory_limit/)
    _(err.message).must_match(/1048576/)
  end

  # The check is a ceiling on the source, so a flat value large enough on its
  # own is refused too, not only one that got there by expanding. A flat value
  # is one value, so the per-element check never sees it: it is measured up
  # front instead, before the copy and the escaping that would otherwise cost
  # twice its size to find out.
  it "refuses a single value larger than the limit" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    _ { vm.define_const(:s, 'x' * 2_000_000) }.must_raise ArgumentError
  end

  # Measured through an unbound String#bytesize, so a subclass answering that
  # one low cannot buy itself the expensive copy.
  #
  # The bytes are not valid UTF-8, which is what makes this test able to fail.
  # Refusing the value is not on its own evidence of anything: the check on the
  # finished literal refuses it too, just after paying for it. Escaping is what
  # would notice the encoding, so ArgumentError says the value was turned away
  # before that ran, and JSON::GeneratorError would say it was not.
  it "refuses one that under-reports its own size, before escaping it" do
    liar = Class.new(String) { def bytesize = 0 }
    invalid = (+"\xC3").b * 2_000_000
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    _ { vm.define_const(:s, liar.new(invalid.force_encoding("UTF-8"))) }.must_raise ArgumentError
  end

  # Redefining an existing binding is an assignment, and an assignment
  # expression evaluates to what was assigned, so eval_code converted the whole
  # value back into Ruby and dropped it. A declaration never did, having no
  # completion value, which is what makes the two comparable here: they
  # serialize the same value, so they should cost about the same to run.
  it "does not convert the value back into Ruby when redefining" do
    vm = Quickjs::VM.new(timeout_msec: 60_000)
    rows = Array.new(20_000) { |i| "row#{i}" }
    GC.start
    before = GC.stat(:total_allocated_objects)
    vm.define_let(:s, rows)
    declaring = GC.stat(:total_allocated_objects) - before

    GC.start
    before = GC.stat(:total_allocated_objects)
    vm.define_let(:s, rows)
    assigning = GC.stat(:total_allocated_objects) - before

    # Both cost about three objects per element to build. The value coming
    # back is one more per element, so half of that is clear of the noise in
    # either direction.
    _(assigning).must_be :<, declaring + rows.size / 2
  end
  # The per-value checks measure raw bytes; escaping expands them. A string of
  # nothing but quotes doubles, so it passes the check on the way in and only
  # the check on the finished literal can catch it. Without that one the VM
  # runs out of memory and is poisoned for good, which is why this asserts the
  # VM survives and not just that something was raised.
  it "catches a value that only goes over budget once it is escaped" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    _ { vm.define_const(:s, %q(") * 1_048_566) }.must_raise ArgumentError

    _(vm.eval_code("1 + 1")).must_equal 2
  end

  # The confirmation that a declaration ran is what keeps a binding we made
  # from being mistaken for one JavaScript will never grant. It was cleared by
  # any failed declaration, and a failed one cannot have removed a binding an
  # earlier one made, so a single refused define in between bricked the name.
  it "keeps a live let usable after a refused define of another form" do
    vm = Quickjs::VM.new
    vm.define_let(:x, 1)
    vm.eval_code(<<~JS)
      Object.defineProperty(globalThis, "x", {
        value: "decoy", configurable: false, writable: true, enumerable: true,
      });
    JS
    _ { vm.define_const(:x, 2) }.must_raise ArgumentError

    vm.define_let(:x, 3)

    _(vm.eval_code("x")).must_equal 3
    _(vm.eval_code(%q{(function () { return this })().x})).must_equal "decoy"
  end

  # And it records which form was declared, not just the name, so a define of a
  # different form that fails cannot leave the previous form's confirmation
  # standing for a binding it never made.
  it "does not carry one form's confirmation over to another" do
    vm = Quickjs::VM.new
    vm.define_var(:x, 1)
    vm.singleton_class.prepend(Module.new do
      def eval_code(source, **options)
        raise ThreadError, "injected" if source.start_with?("let x =")

        super
      end
    end)
    _ { vm.define_let(:x, 2) }.must_raise ThreadError

    _ { vm.define_let(:x, 3) }.must_raise ArgumentError

    _(vm.eval_code(%q{(function () { return this })().x})).must_equal 1
  end

  # A Ruby thread gets a fraction of the main stack, and QuickJS clamps its own
  # limit to the same headroom, so there is a band where the parser gives out
  # while the Ruby walk still had room. The caller is told to rescue
  # ArgumentError, and on a worker thread a raw Quickjs::SyntaxError is fatal.
  it "raises the same error when the parser runs out first" do
    raised = [400, 550, 700, 1500].map do |depth|
      value = (1..depth).reduce([1]) { |inner, _| [inner] }
      ::Thread.new do
        vm = Quickjs::VM.new
        begin
          vm.define_const(:deep, value)
          :accepted
        rescue ArgumentError
          :refused
        end
      end.value
    end

    _(raised).must_equal [:accepted, :refused, :refused, :refused]
  end
  # undefined, NaN and Infinity are not literals in JavaScript, they are
  # properties of the global object, and QuickJS lets a guest redefine them
  # with defineProperty even though the spec says it should not. Writing them
  # by name handed the guest the value, at any depth, for const and let as much
  # as var. The declaration forms are refused, which is what made this look
  # settled for a long time: `let NaN = 5` is a SyntaxError, defineProperty is
  # not.
  it "spells the four global-named values so a guest cannot redefine them" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      Object.defineProperty(globalThis, "undefined", { value: { stolen: true } });
      Object.defineProperty(globalThis, "NaN", { value: 999 });
      Object.defineProperty(globalThis, "Infinity", { value: -1 });
    JS

    vm.define_const(:a, Quickjs::Value::UNDEFINED)
    vm.define_const(:b, Quickjs::Value::NAN)
    vm.define_const(:c, Float::INFINITY)
    vm.define_const(:d, -Float::INFINITY)
    vm.define_const(:f, Float::NAN)
    vm.define_const(:e, { "x" => Quickjs::Value::UNDEFINED, "y" => Float::NAN })

    _(vm.eval_code("typeof a")).must_equal "undefined"
    _(vm.eval_code("Number.isNaN(b)")).must_equal true
    _(vm.eval_code("c")).must_equal Float::INFINITY
    _(vm.eval_code("d")).must_equal(-Float::INFINITY)
    _(vm.eval_code("Number.isNaN(f)")).must_equal true
    _(vm.eval_code("typeof e.x")).must_equal "undefined"
    _(vm.eval_code("Number.isNaN(e.y)")).must_equal true
  end

  # The guard asks the VM about its globals, and a VM that has stopped working
  # will fail that question for reasons that have nothing to do with globals.
  # Reporting a dead VM as an ArgumentError about the caller's name is the
  # mistake the const branch already has a test against.
  it "does not report a poisoned VM as a problem with the global" do
    vm = Quickjs::VM.new(memory_limit: 2 * 1024 * 1024, timeout_msec: 30_000)
    begin
      vm.eval_code("globalThis.hold = []; for (;;) { hold.push(new Array(64).fill(0)); }")
    rescue Quickjs::RuntimeError
    end

    err = _ { vm.define_var(:x, 1) }.must_raise Quickjs::RuntimeError

    _(err.message).must_match(/poisoned/)
  end

  # Refusing a name the VM can never give us must not refuse the ones it
  # already gave us. A binding we declared is there for good, so a later
  # refusal of the bare declaration is a redeclaration of our own.
  it "still redefines a let the guest has shadowed with a fixed global" do
    vm = Quickjs::VM.new
    vm.define_let(:cfg, 1)
    vm.eval_code(<<~JS)
      Object.defineProperty(globalThis, "cfg", {
        value: "guest", configurable: false, writable: true, enumerable: true,
      });
    JS

    vm.define_let(:cfg, 2)

    _(vm.eval_code("cfg")).must_equal 2
    _(vm.eval_code(%q{(function () { return this })().cfg})).must_equal "guest"
  end

  it "still redefines one when the VM cannot be asked about it" do
    vm = Quickjs::VM.new
    vm.define_let(:u, Quickjs::Value::UNDEFINED)
    vm.eval_code("Object = null;")

    vm.define_let(:u, 2)

    _(vm.eval_code("u")).must_equal 2
  end
  # A non-configurable property of the global object makes a lexical
  # declaration of that name impossible for good, and a guest top-level `var`
  # creates exactly that shape. Letting the refusal pass left nothing for the
  # assignment to find, so it wrote the global: a define_let on globalThis.
  # The sibling test below uses a configurable property, which is the one
  # variant where the declaration succeeds and shadows.
  it "refuses a let the VM can never give it, rather than writing the global" do
    vm = Quickjs::VM.new
    vm.eval_code("var owned = 'guest';")
    vm.instance_variable_set(:@_defined_variables, { "owned" => :let })

    err = _ { vm.define_let(:owned, { "api_key" => "s3cret" }) }.must_raise ArgumentError

    _(err.message).must_match(/cannot be configured away/)
    _(vm.eval_code(%q{(function () { return this })().owned})).must_equal "guest"
  end
  # define_var promises the value is visible on globalThis. A guest lexical of
  # the same name refuses the declaration, and swallowing that let the
  # assignment write the guest's binding and report success for a define that
  # never reached globalThis at all.
  it "does not report success when a guest lexical took the name" do
    vm = Quickjs::VM.new
    vm.eval_code("let CFG = 'guest';")
    vm.instance_variable_set(:@_defined_variables, { "CFG" => :var })

    _ { vm.define_var(:CFG, { "secret" => 1 }) }.must_raise Quickjs::SyntaxError

    _(vm.eval_code("CFG")).must_equal "guest"
  end

  # The descriptor is read with nothing dispatched and nothing inherited. Going
  # through hasOwnProperty only moved the problem: that is a method a guest can
  # replace, and `writable` was still read through the chain, so two gadgets
  # together made an accessor answer "writable" and its setter took the value.
  it "does not let two prototype gadgets disguise an accessor" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      globalThis.stolen = null;
      Object.defineProperty(globalThis, "CFG", {
        configurable: true, get() { return "innocent" }, set(v) { stolen = v },
      });
      Object.prototype.writable = true;
      Object.prototype.hasOwnProperty = function () { return false };
    JS

    _ { vm.define_var(:CFG, { "api_key" => "s3cret" }) }.must_raise ArgumentError

    _(vm.eval_code("stolen")).must_be_nil
  end

  # The two probes ask different questions and must keep walking different
  # chains. This one has to see an inherited name, or it would call it lexical,
  # skip the declaration, and let the assignment reach an inherited setter.
  it "sees a name inherited from Object.prototype as not lexical" do
    vm = Quickjs::VM.new
    vm.eval_code("Object.prototype.INH = 1;")

    _(vm.send(:_live_lexical?, "INH")).must_equal false

    vm.define_let(:INH, 2)
    vm.define_let(:INH, 3)

    _(vm.eval_code("INH")).must_equal 3
    _(vm.eval_code(%q{Object.prototype.hasOwnProperty.call((function () { return this })(), "INH")})).must_equal false
  end

  # The guard runs on the redefine path too. A var we declared is
  # non-configurable so it cannot become an accessor, but it can be made
  # non-writable, and then the assignment would be discarded in sloppy mode.
  it "refuses a redefine onto a var that has been made non-writable" do
    vm = Quickjs::VM.new
    vm.define_var(:v, 1)
    vm.eval_code("Object.defineProperty(globalThis, 'v', { writable: false });")

    err = _ { vm.define_var(:v, 2) }.must_raise ArgumentError

    _(err.message).must_match(/not writable/)
    _(vm.eval_code("v")).must_equal 1
  end

  # And on the path that changes binding form, which declares a var it has no
  # record of.
  it "refuses a form change onto a global it cannot write" do
    vm = Quickjs::VM.new
    # Only the record, with no live let: with one, the declaration is refused
    # for being a redeclaration and the guard never has to answer, which is how
    # this test used to pass with the guard deleted.
    vm.instance_variable_set(:@_defined_variables, { "w" => :let })
    vm.eval_code(<<~JS)
      globalThis.stolen = null;
      Object.defineProperty(globalThis, "w", {
        configurable: true, get() { return 1 }, set(v) { stolen = v },
      });
    JS

    err = _ { vm.define_var(:w, 2) }.must_raise ArgumentError

    _(err.message).must_match(/accessor/)
    _(vm.eval_code("stolen")).must_be_nil
  end  # Extensibility decides whether a property can be added, so it has nothing to
  # say about a name already there. Asking first refused a redefine the VM
  # would have taken, and told the caller why in terms that were not true.
  it "redefines a var on a sealed global, which JavaScript allows" do
    vm = Quickjs::VM.new
    vm.define_var(:cfg, 1)
    vm.eval_code("Object.preventExtensions(globalThis);")

    vm.define_var(:cfg, 2)

    _(vm.eval_code("cfg")).must_equal 2
  end

  # A descriptor is an ordinary object, so reading `get` off it walks the
  # prototype chain. A stray Object.prototype.get made every var read as an
  # accessor and refused it for a reason that was not there.
  it "does not read the descriptor through Object.prototype" do
    vm = Quickjs::VM.new
    vm.eval_code("globalThis.cfg = 1; Object.prototype.get = 1;")

    vm.define_var(:cfg, 2)

    _(vm.eval_code("cfg")).must_equal 2
  end
  # A key is a value the caller supplies, and the up-front check was on the
  # value path only, so a large String cost nothing as a value and was copied
  # and escaped as a key before anything looked at it. Same discriminator: the
  # bytes are invalid UTF-8, so JSON::GeneratorError would say the escaping
  # ran.
  it "refuses an oversized key before escaping it" do
    liar = Class.new(String) { def bytesize = 0 }
    invalid = (+"\xC3").b * 2_000_000
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    _ { vm.define_const(:h, { liar.new(invalid.force_encoding("UTF-8")) => 1 }) }
      .must_raise ArgumentError
  end

  it "refuses an oversized Symbol, in either position" do
    huge = ("s" * 2_000_000).to_sym
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    _ { vm.define_const(:a, huge) }.must_raise ArgumentError
    _ { vm.define_const(:b, { huge => 1 }) }.must_raise ArgumentError
  end
  # An Integer costs its digits to render, so the same check applies before
  # rendering rather than to the finished literal.
  #
  # Unlike the String above, nothing here distinguishes the two paths in what
  # the caller sees: without the up-front check the digits get rendered and the
  # check on the finished literal refuses the same value with the same error.
  # Only the cost differs, measured at 1.16s for a 40 Mbit value against zero,
  # and a wall-clock assertion on CI is not worth the flake. So this pins the
  # refusal and not where it came from.
  it "refuses an Integer with more digits than the limit" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    _ { vm.define_const(:n, 2**(8 * 1024 * 1024)) }.must_raise ArgumentError
  end

  # That check is deliberately loose, so what matters is that it refuses only
  # what is certainly too large. A bignum whose digits fit still goes through.
  it "leaves an Integer whose digits fit alone" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    vm.define_const(:n, 10**300_000)

    _(vm.eval_code("n")).must_equal Float::INFINITY
  end

  # Cycle detection asks whether it has seen this object before, so it must
  # not ask the object. Keying on value.object_id let a Hash subclass answer,
  # in either direction.
  it "does not call an acyclic structure circular because it says so" do
    fixed = Class.new(Hash) { def object_id = 12_345 }
    inner = fixed.new
    inner["b"] = 1
    outer = fixed.new
    outer["a"] = inner
    vm = Quickjs::VM.new

    vm.define_let(:nested, outer)

    _(vm.eval_code("JSON.stringify(nested)")).must_equal %q({"a":{"b":1}})
  end

  it "still catches a cycle that reports a new identity every time" do
    shifty = Class.new(Hash) { def object_id = rand(1 << 62) }
    cyclic = shifty.new
    cyclic["self"] = cyclic
    vm = Quickjs::VM.new

    err = _ { vm.define_let(:c, cyclic) }.must_raise ArgumentError

    _(err.message).must_match(/circular/)
  end
  # Which branch a value takes decides the shape that reaches JS, so the test
  # for it must not be one the value answers.
  it "does not let a container choose which shape it is written as" do
    liar_hash = Class.new(Hash) { def is_a?(_) = true }
    hash = liar_hash.new
    hash["a"] = 1
    liar_array = Class.new(Array) { def is_a?(_) = false }
    vm = Quickjs::VM.new

    vm.define_let(:h, hash)
    vm.define_let(:a, liar_array.new([1, 2]))

    _(vm.eval_code("JSON.stringify(h)")).must_equal %q({"a":1})
    _(vm.eval_code("JSON.stringify(a)")).must_equal "[1,2]"
  end
  # Sharing is only a problem when it compounds. One object under two keys
  # is ordinary and stays allowed.
  it "leaves an ordinary shared reference alone" do
    vm = Quickjs::VM.new
    shared = { n: 1 }

    vm.define_const(:pair, { x: shared, y: shared })

    _(vm.eval_code('JSON.stringify(pair)')).must_equal '{"x":{"n":1},"y":{"n":1}}'
  end

  it "leaves values that fit alone" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    vm.define_const(:fits, doubling(8))

    _(vm.eval_code('fits.length')).must_equal 2
  end
end

describe "a Hash key named __proto__" do
  # `{"__proto__": v}` in an object literal sets the prototype rather than
  # defining a property, quoted or not, so the entry used to disappear and
  # its contents became inherited members of the object instead.
  it "becomes a property rather than the prototype" do
    vm = Quickjs::VM.new

    vm.define_const(:o, { '__proto__' => { 'p' => 1 } })

    _(vm.eval_code('Object.getOwnPropertyNames(o).length')).must_equal 1
    _(vm.eval_code('JSON.stringify(o)')).must_equal '{"__proto__":{"p":1}}'
    _(vm.eval_code('o.p')).must_equal Quickjs::Value::UNDEFINED
  end

  it "survives a round trip" do
    vm = Quickjs::VM.new
    sent = { 'name' => 'bob', '__proto__' => { 'isAdmin' => true } }

    vm.define_const(:r, sent)

    _(vm.eval_code('r')).must_equal sent
  end

  # The key can sit at any depth, which is what makes a host-side check on
  # the top level insufficient: in Ruby it reads as an ordinary key with a
  # Hash under it, and in JS it used to arrive as members of the object.
  it "does not inject through a nested key" do
    vm = Quickjs::VM.new

    vm.define_const(:payload, { 'user' => { '__proto__' => { 'isAdmin' => true } } })

    _(vm.eval_code('payload.user.isAdmin')).must_equal Quickjs::Value::UNDEFINED
    _(vm.eval_code('Object.getOwnPropertyNames(payload.user).length')).must_equal 1
  end

  # A null prototype used to break ordinary guest code on the object.
  it "does not produce a null-prototype object" do
    vm = Quickjs::VM.new

    vm.define_const(:np, { '__proto__' => nil })

    _(vm.eval_code("np.hasOwnProperty('__proto__')")).must_equal true
  end

  # Only the generated source changes. JavaScript written by hand keeps the
  # semantics the language gives it.
  it "leaves JS written by the guest alone" do
    vm = Quickjs::VM.new

    _(vm.eval_code('Object.getOwnPropertyNames({__proto__: {p: 1}}).length')).must_equal 0
    _(vm.eval_code('({__proto__: {p: 1}}).p')).must_equal 1
  end
end

describe "values the serializer must not take at face value" do
  # to_json is dispatched on the caller's object, so a String subclass could
  # decide what went into the source. The key path was already written as
  # to_s.to_json; the value path was not, and this executed.
  it "does not let a String subclass write the source" do
    evil = Class.new(String) do
      def to_json(*) = %q{1; globalThis.PWNED = 'yes'; var zz = 1}
    end
    vm = Quickjs::VM.new

    vm.define_let(:v, evil.new('hi'))

    _(vm.eval_code('v')).must_equal 'hi'
    _(vm.eval_code('globalThis.PWNED')).must_equal Quickjs::Value::UNDEFINED
  end

  # Answering that with to_s.to_json only moved the dispatch one method along:
  # to_s belongs to the caller's object as much as to_json does, in the value
  # position and in the key position alike.
  it "does not let a String subclass write the source through to_s either" do
    evil = Class.new(String) do
      def to_s
        obj = Object.new
        def obj.to_json(*) = %q{1; globalThis.PWNED = 'yes'; var zz = 1}
        obj
      end
    end
    vm = Quickjs::VM.new

    vm.define_let(:v, evil.new('hi'))
    vm.define_let(:h, { 'a' => 0, evil.new('k') => 1 })

    _(vm.eval_code('v')).must_equal 'hi'
    _(vm.eval_code('JSON.stringify(h)')).must_equal '{"a":0,"k":1}'
    _(vm.eval_code('globalThis.PWNED')).must_equal Quickjs::Value::UNDEFINED
  end

  # No hostile value is needed at all when a gem has replaced String#to_json
  # process-wide. The escaping has to be ours.
  it "escapes strings itself rather than through String#to_json" do
    vm = Quickjs::VM.new
    String.class_eval { def to_json(*) = '"replaced"' }

    begin
      vm.define_let(:v, 'kept')
      vm.define_let(:s, :also_kept)
      vm.define_let(:h, { 'k' => 'kept too' })
    ensure
      String.class_eval { remove_method :to_json }
    end

    _(vm.eval_code('v')).must_equal 'kept'
    _(vm.eval_code('s')).must_equal 'also_kept'
    _(vm.eval_code('JSON.stringify(h)')).must_equal %q({"k":"kept too"})
  end

  # Integer and Float cannot be subclassed, so this one needs a process-wide
  # patch rather than a hostile value. That is the same tier as replacing
  # String#to_json, which the String path already answers.
  it "reads numbers itself rather than asking them to describe themselves" do
    vm = Quickjs::VM.new
    Integer.class_eval do
      alias_method :_orig_to_s, :to_s
      def to_s(*args) = self == 424_242 ? "1; globalThis.PWNED = 1; var zz" : _orig_to_s(*args)
    end
    Float.class_eval do
      alias_method :_orig_to_s, :to_s
      def to_s(*args) = self == 1.5 ? "1; globalThis.PWNED = 1; var zz" : _orig_to_s(*args)
    end

    begin
      vm.define_let(:i, 424_242)
      vm.define_let(:f, 1.5)
    ensure
      Integer.class_eval { remove_method(:to_s); alias_method :to_s, :_orig_to_s; remove_method :_orig_to_s }
      Float.class_eval { remove_method(:to_s); alias_method :to_s, :_orig_to_s; remove_method :_orig_to_s }
    end

    _(vm.eval_code("i")).must_equal 424_242
    _(vm.eval_code("f")).must_equal 1.5
    _(vm.eval_code("typeof globalThis.PWNED")).must_equal "undefined"
  end

  # nan?, infinite? and positive? each decided which of three fixed strings was
  # written, and each was the caller's Float to answer. Float#to_s spells all
  # three the way JavaScript does, so the branches went rather than moving.
  it "does not let a Float choose which literal it is written as" do
    vm = Quickjs::VM.new
    ::Float.class_eval do
      alias_method :_orig_nan?, :nan?
      def nan? = self == 1.5 ? true : _orig_nan?
    end

    begin
      vm.define_let(:f, 1.5)
    ensure
      ::Float.class_eval { remove_method(:nan?); alias_method :nan?, :_orig_nan?; remove_method :_orig_nan? }
    end

    _(vm.eval_code("f")).must_equal 1.5
  end

  it "still spells the three Floats JavaScript has words for" do
    vm = Quickjs::VM.new

    vm.define_let(:n, Float::NAN)
    vm.define_let(:i, Float::INFINITY)
    vm.define_let(:m, -Float::INFINITY)

    _(vm.eval_code("Number.isNaN(n)")).must_equal true
    _(vm.eval_code("i")).must_equal Float::INFINITY
    _(vm.eval_code("m")).must_equal(-Float::INFINITY)
  end

  # The two special Symbols were recognised with ==, which a Symbol answers.
  it "does not let a Symbol claim to be the undefined marker" do
    vm = Quickjs::VM.new
    ::Symbol.class_eval do
      alias_method :_orig_eq, :==
      def ==(_) = true
    end

    begin
      vm.define_let(:s, :hello)
    ensure
      ::Symbol.class_eval { remove_method(:==); alias_method :==, :_orig_eq; remove_method :_orig_eq }
    end

    _(vm.eval_code("s")).must_equal "hello"
  end
  # format looked like it read the number rather than asking it, but it is
  # replaceable too, and unlike Array#join and String#initialize it fails open:
  # whatever the patch returns goes into the source.
  it "does not build numeric literals through a replaceable format" do
    vm = Quickjs::VM.new
    ::Kernel.module_eval do
      alias_method :_orig_format, :format
      def format(*) = "0; globalThis.pwned = 1; var zz"
    end

    begin
      vm.define_let(:i, 42)
      vm.define_let(:h, { 7 => "seven" })
    ensure
      ::Kernel.module_eval { remove_method(:format); alias_method :format, :_orig_format; remove_method :_orig_format }
    end

    _(vm.eval_code("i")).must_equal 42
    _(vm.eval_code(%q(h["7"]))).must_equal "seven"
    _(vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
  end
  # Float#to_s writes the shortest form that reads back as the same double, and
  # is taken as an unbound method so a patched one cannot redirect it.
  it "round-trips floats" do
    vm = Quickjs::VM.new
    values = [0.1, 1.5, -2.25, 1e20, 1e-7, 1e308, 5e-324, 3.141592653589793, 1.0 / 3]

    values.each_with_index { |f, i| vm.define_let(:"f#{i}", f) }

    values.each_with_index { |f, i| _(vm.eval_code("f#{i}")).must_equal f }
  end
  # A wide container walks past a check that only runs on the finished
  # container, since map and join materialise it first. Refusing it is not
  # enough to show that, since the old check refused it too, just later. The
  # last element is a value this converter cannot represent: reaching it would
  # raise TypeError, so ArgumentError is what says the walk stopped short.
  it "stops on a wide container rather than after building it" do
    leaf = Array.new(5_000) { |i| i }
    tripwire = Object.new
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    _ { vm.define_let(:v, { 'items' => Array.new(300) { leaf } + [tripwire] }) }
      .must_raise ArgumentError
  end

  # A depth constant cannot be right: a Ruby thread's stack is a fraction of the
  # main thread's, so the same 900 levels are fine on one and fatal on the
  # other. The guard is the stack itself, and SystemStackError is not a
  # StandardError, so a caller's `rescue => e` would miss it.
  it "refuses a structure deeper than the stack it is walked on" do
    deep = (1..100_000).reduce({ n: 1 }) { |inner, _| { n: inner } }
    vm = Quickjs::VM.new

    err = _ { vm.define_const(:deep, deep) }.must_raise ArgumentError

    _(err.message).must_match(/deeply/)
  end

  it "refuses it on a small stack too, rather than killing the fiber" do
    deep = (1..100_000).reduce({ n: 1 }) { |inner, _| { n: inner } }
    vm = Quickjs::VM.new

    result = Fiber.new do
      begin
        vm.define_const(:deep, deep)
        :accepted
      rescue ArgumentError
        :refused
      end
    end.resume

    _(result).must_equal :refused
  end

  it "still takes a structure a normal stack can hold" do
    deep = (1..500).reduce({ n: 1 }) { |inner, _| { n: inner } }
    vm = Quickjs::VM.new

    vm.define_const(:ok, deep)

    _(vm.eval_code('typeof ok')).must_equal 'object'
  end

  # A refused value must not leave the name half declared. Every check that
  # can refuse one runs before the declaration is evaluated, so the caller can
  # fix the value and use the same name. Two things get past those checks into
  # the eval itself: running out of memory, which poisons the whole VM rather
  # than one binding, and the timeout below.
  it "leaves the name usable after refusing a value" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)
    refused = [
      { 'a' => Array.new(300) { Array.new(5_000) { |i| i } } },
      Time.now,
      (1..100_000).reduce({ n: 1 }) { |inner, _| { n: inner } },
    ]

    refused.each do |value|
      _ { vm.define_let(:v, value) }.must_raise StandardError
    end
    vm.define_let(:v, 'fine')

    _(vm.eval_code('v')).must_equal 'fine'
  end

  # Rendering a JS exception announces it to on_log before raising, so asking
  # whether a binding is live by provoking a redeclaration error put a
  # console.error the caller never wrote into their log stream, once per
  # redefine, on a path that succeeded. This is the README's own example.
  it "does not log when the binding reads as a live lexical" do
    logged = []
    vm = Quickjs::VM.new
    vm.on_log { |entry| logged << [entry.severity, entry.raw.to_s] }

    vm.define_let(:counter, 1)
    vm.define_let(:counter, 2)
    vm.define_var(:v, 1)
    vm.define_var(:v, 2)
    vm.define_const(:c, 1)
    _ { vm.define_const(:c, 2) }.must_raise ArgumentError

    _(logged).must_equal []
    _(vm.eval_code("counter")).must_equal 2
  end

  # The check cannot answer for a binding holding undefined, or one shadowing a
  # guest global of the same name, so those two still fall back to provoking the
  # error and still log. Pinned rather than left to the comment, since the shape
  # above reads as a general promise and this is where it stops.
  it "still logs for the two shapes the check cannot answer for" do
    holding_undefined = Quickjs::VM.new
    rows = []
    holding_undefined.on_log { |entry| rows << entry.severity }
    holding_undefined.define_let(:u, Quickjs::Value::UNDEFINED)
    holding_undefined.define_let(:u, 2)

    _(rows).must_equal [:error]
    _(holding_undefined.eval_code("u")).must_equal 2

    shadowing = Quickjs::VM.new
    rows = []
    shadowing.on_log { |entry| rows << entry.severity }
    shadowing.eval_code("globalThis.s = 'guest';")
    shadowing.define_let(:s, 1)
    shadowing.define_let(:s, 2)

    _(rows).must_equal [:error]
    _(shadowing.eval_code("s")).must_equal 2
    _(shadowing.eval_code("globalThis.s")).must_equal "guest"
  end

  # Refusing a const redefine asks by attempting the declaration, so it has to
  # tell the redeclaration it went looking for apart from the VM failing under
  # it. Reporting an out-of-memory as "you redefined a const" tells the caller
  # they made a mistake while the VM is dead.
  it "does not report a failing VM as a redefinition" do
    vm = Quickjs::VM.new(memory_limit: 4 * 1024 * 1024)
    # UNDEFINED so the cheap liveness check cannot answer, which is what makes
    # the declaration actually run.
    vm.define_const(:cfg, Quickjs::Value::UNDEFINED)

    err = _ { vm.define_const(:cfg, Array.new(300_000) { |i| i }) }.must_raise Quickjs::RuntimeError

    _(err.message).must_match(/out of memory/)
  end

  # The name goes into the same source as the value, and was the one piece of
  # it with no bound. An oversized value is refused and the VM carries on; an
  # oversized name reached the eval and took the VM with it.
  it "refuses a name too long to fit the budget, without hurting the VM" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

    err = _ { vm.define_const(("n" * 8_000_000).to_sym, 1) }.must_raise ArgumentError

    _(err.message).must_match(/memory_limit/)
    _(vm.eval_code("1 + 1")).must_equal 2
  end
  # The one branch still acting on the record alone. A record that ran ahead of
  # a declaration that never happened refused a legitimate change of form, and
  # went on refusing it for the life of the VM.
  it "lets a form change through when the other form is not really there" do
    vm = Quickjs::VM.new(timeout_msec: 60_000)
    vm.define_let(:warm, 1)
    busy = ::Thread.new do
      vm.eval_code("let s = 0; for (let i = 0; i < 60000000; i++) s += i; s")
    rescue StandardError
      nil
    end
    sleep 0.05
    begin
      vm.define_let(:n, 1)
    rescue ThreadError
    end
    busy.join
    skip "the define was not refused in the window" unless vm.eval_code("typeof n") == "undefined"

    vm.define_var(:n, 7)

    _(vm.eval_code("n")).must_equal 7
    _(vm.eval_code("globalThis.n")).must_equal 7
  end

  it "still refuses a form change when the other form is there" do
    vm = Quickjs::VM.new
    vm.define_let(:real, 1)

    err = _ { vm.define_var(:real, 2) }.must_raise ArgumentError

    _(err.message).must_match(/already defined as a let/)
    _(vm.eval_code("real")).must_equal 1
  end
  # The guard read the `globalThis` property, which is writable, so pointing it
  # at a decoy made the probe answer about the decoy while the value went to
  # whatever the real global still had sitting there. Reachable from Ruby alone
  # with define_var(:globalThis, 1).
  it "sees past a globalThis that has been pointed at a decoy" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      globalThis.sink = [];
      Object.defineProperty(globalThis, "x", {
        get() { return "GETTER" },
        set(v) { sink.push(v) },
        configurable: true,
      });
      globalThis = {};
    JS

    _ { vm.define_var(:x, { "a" => 1 }) }.must_raise ArgumentError

    _(vm.eval_code("JSON.stringify(sink)")).must_equal "[]"
  end
  # A sealed globalThis refuses a var declaration at runtime. The guard exists
  # so that a var the VM cannot be given raises ArgumentError rather than some
  # other class from further in.
  it "refuses a var when globalThis takes no new properties" do
    vm = Quickjs::VM.new
    vm.eval_code("Object.preventExtensions(globalThis);")

    err = _ { vm.define_var(:n, 1) }.must_raise ArgumentError

    _(err.message).must_match(/extensible/)
  end
  # Assigning to a name with no binding writes globalThis: sloppy mode invents
  # the property, and strict mode is no answer either, since it only refuses to
  # invent one and writes a global that already exists quite happily. The bare
  # declaration before the assignment is what keeps a let off globalThis, and a
  # guest global of the same name is the case that shows it.
  it "keeps a let off globalThis even when the guest owns that name" do
    vm = Quickjs::VM.new(timeout_msec: 60_000)
    vm.eval_code("globalThis.owned = 'guest';")
    vm.define_let(:warm, 1)
    # The record has to be ahead of a declaration that never ran, since that is
    # the only state in which the assignment meets a name with no binding. Same
    # way the test above produces it.
    busy = ::Thread.new do
      vm.eval_code("let s = 0; for (let i = 0; i < 60000000; i++) s += i; s")
    rescue StandardError
      nil
    end
    sleep 0.05
    begin
      vm.define_let(:owned, 1)
    rescue ThreadError
    end
    busy.join
    skip "the define was not refused in the window" unless vm.eval_code("typeof owned") == "string"

    vm.define_let(:owned, 42)

    _(vm.eval_code("owned")).must_equal 42
    _(vm.eval_code("globalThis.owned")).must_equal "guest"
  end
  # Strict mode refuses these two as assignment targets while the declaration,
  # which is sloppy, accepts them. A strict assignment made them definable once
  # and broken every time after.
  it "can redefine a name JavaScript only restricts in strict mode" do
    vm = Quickjs::VM.new

    %i[eval arguments].each do |name|
      vm.define_let(name, 1)
      vm.define_let(name, 2)

      _(vm.eval_code(name.to_s)).must_equal 2
    end
  end

  # Asking whether a const is really there by assigning to it ran the guest's
  # getter and setter, inside a call that is only meant to be asking. The
  # declaration answers the same question at parse time, before anything runs.
  it "asks about a const without running anything of the guest's" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      globalThis.hits = [];
      Object.defineProperty(globalThis, "acc", {
        configurable: true,
        get() { hits.push("get"); return 1 },
        set(v) { hits.push("set") },
      });
    JS
    vm.define_const(:acc, 1)

    _ { vm.define_const(:acc, 2) }.must_raise ArgumentError

    _(vm.eval_code("JSON.stringify(hits)")).must_equal "[]"
  end
  # Recording before the eval inverts which way the window can be wrong, so it
  # needs its own case: a record standing for a declaration that never ran. The
  # VM refusing a second define, or quietly turning a let into a global, are
  # both worse than what the ordering was introduced to fix.
  it "corrects a record that ran ahead of its declaration" do
    reached = 0
    # const and let only. A var probes globalThis before it declares, and that
    # probe is the eval that raises, so no record is ever recorded ahead.
    %i[const let].each do |kind|
      vm = Quickjs::VM.new(timeout_msec: 60_000)
      vm.define_let(:warm, 1)
      busy = ::Thread.new do
        vm.eval_code("let s = 0; for (let i = 0; i < 60000000; i++) s += i; s")
      rescue StandardError
        nil
      end
      sleep 0.05
      begin
        vm.public_send(:"define_#{kind}", :cfg, 1)
      rescue ThreadError
      end
      busy.join
      reached += 1 if vm.eval_code("typeof cfg") == "undefined"
      next unless vm.eval_code("typeof cfg") == "undefined"

      vm.public_send(:"define_#{kind}", :cfg, 2)

      _(vm.eval_code("cfg")).must_equal 2
      # A let or const that reached the VM through an assignment would have
      # been invented as a global by sloppy mode.
      _(vm.eval_code("typeof globalThis.cfg")).must_equal "undefined"
    end

    # Both siblings of this test say so when the window was missed; without
    # this it would report a pass having asserted nothing.
    skip "neither define was refused in the window" if reached.zero?
  end
  # Thread.handle_interrupt defers Timeout and Thread#raise. It does not defer
  # a trap handler: that runs at the checkpoint regardless of the mask, and a
  # raise inside it is an ordinary raise from that point. So the record goes in
  # before the eval rather than after, and this is the case that says so.
  #
  # In a child process, because the signal is the point of the test and a
  # signal that arrives late has the whole process to land in. It did: an
  # earlier version of this test killed an unrelated crypto test on five CI
  # runners after its own trap had been restored.
  it "does not lose the record when a trap handler raises" do
    skip "fork is not available here" unless Process.respond_to?(:fork)

    pid = fork do
      shutdown = Class.new(StandardError)
      trap("USR2") { raise shutdown, "down" }
      status = 2 # nothing landed in the window
      3.times do
        vm = Quickjs::VM.new
        value = Array.new(400_000) { |i| i }
        me = Process.pid
        ::Thread.new { sleep 0.03; Process.kill("USR2", me) }
        begin
          vm.define_let(:cfg, value)
        rescue shutdown
        end
        next if vm.eval_code("typeof cfg") == "undefined"

        status = 0
        begin
          vm.define_let(:cfg, 1)
        rescue Quickjs::SyntaxError
          status = 1 # the name is bricked
        rescue ArgumentError
        end
        break
      end
      exit!(status)
    end
    _, result = Process.waitpid2(pid)

    skip "the signal never landed in the window" if result.exitstatus == 2
    _(result.exitstatus).must_equal 0
  end
  # eval_code is a C call, so a pending Timeout or Thread#raise is delivered at
  # the first Ruby checkpoint after it returns. That checkpoint used to be the
  # gap between a binding that now exists in the VM and the line that records
  # it, which is where such an exception lands rather than a narrow race.
  it "does not lose the record when a Timeout lands on the declaration" do
    bricked = 0
    reached = 0

    12.times do
      vm = Quickjs::VM.new
      value = Array.new(120_000) { |i| i }
      begin
        Timeout.timeout(0.05) { vm.define_let(:tv, value) }
      rescue Timeout::Error
      end
      next if vm.eval_code("typeof tv") == "undefined"

      reached += 1
      begin
        vm.define_let(:tv, 1)
      rescue Quickjs::SyntaxError
        bricked += 1
      rescue ArgumentError
      end
    end

    _(bricked).must_equal 0
    # Whether the timeout lands inside the window depends on how fast the box
    # is: too slow and it fires while Ruby is still building the literal, too
    # fast and the define finishes first. Either way every iteration would skip
    # and this would pass having tested nothing, so say when that happened.
    skip "the timeout never landed in the window on this machine" if reached.zero?
  end
  # An interrupt lands after QuickJS has created the binding and before it is
  # initialized, so the name stays in the temporal dead zone for the life of an
  # otherwise healthy VM. Nothing can undo that; what it must not do is report
  # a redeclaration the caller never wrote.
  it "says so when a name was left uninitialized by an interrupt" do
    vm = Quickjs::VM.new(timeout_msec: 1)
    _ { vm.define_const(:y, Array.new(400_000) { |i| i }) }.must_raise Quickjs::InterruptedError

    err = _ { vm.define_const(:y, 1) }.must_raise ArgumentError

    _(err.message).must_match(/uninitialized/)
    _(vm.eval_code("1 + 1")).must_equal 2
  end
  # memory_usage walks the whole JS heap, and the limit it reports is fixed
  # when the VM is built, so asking per call made every define scale with how
  # much the VM was holding.
  it "reads the memory limit once per VM rather than per define" do
    vm = Quickjs::VM.new(memory_limit: 1024 * 1024)
    vm.define_let(:a, 1)
    asked = 0
    vm.define_singleton_method(:memory_usage) do
      asked += 1
      super()
    end

    vm.define_let(:b, 2)

    _(asked).must_equal 0
    _ { vm.define_let(:c, 3_000_000.times.map { 0 }) }.must_raise ArgumentError
  end
  # malloc_limit is an int64_t, so a limit at or above 2**63 reads back
  # negative and every define compared against it.
  it "works on a VM whose memory_limit reads back negative" do
    vm = Quickjs::VM.new(memory_limit: 2**63)

    vm.define_let(:a, 1)

    _(vm.eval_code('a')).must_equal 1
  end
end

describe "when the VM can no longer answer about its own globals" do
  # The guard reads globalThis and Object through JS, so a caller that has
  # replaced either has taken the check away from itself. Both used to end in
  # a define that reported success it did not have, or in an error naming
  # nothing.
  # The probe reads the real global object rather than the `globalThis`
  # property, so replacing that property no longer blinds it: it sees the
  # accessor and says so. The message is what distinguishes the two, since a
  # bare ArgumentError would also be what a blinded probe raised.
  it "still sees the accessor once globalThis has been replaced" do
    vm = Quickjs::VM.new
    vm.eval_code("Object.defineProperty(globalThis, 'acc', { configurable: true, set(v) {}, get() { return 7 } });")
    vm.define_var(:globalThis, 1)

    err = _ { vm.define_var(:acc, 5) }.must_raise ArgumentError

    _(err.message).must_match(/accessor/)
  end

  # The liveness check builds a small piece of JavaScript around the caller's
  # name, so any identifier that source declares is one the caller must not be
  # able to collide with. It declared one in the scope that then resolved the
  # name, and answered "live" for it on a VM that had never heard of it.
  it "does not answer for its own locals" do
    vm = Quickjs::VM.new

    %w[root g key literal kind name value].each do |candidate|
      _(vm.eval_code("typeof #{candidate}")).must_equal "undefined"
      _(vm.send(:_live_lexical?, candidate)).must_equal false
    end
  end

  it "keeps a let named after one of them off globalThis too" do
    vm = Quickjs::VM.new
    # The record ahead of a declaration that never ran, injected rather than
    # raced for, since the name is what this is about and not the timing.
    vm.instance_variable_set(:@_defined_variables, { "root" => :let })

    vm.define_let(:root, 42)

    _(vm.eval_code("root")).must_equal 42
    _(vm.eval_code("typeof globalThis.root")).must_equal "undefined"
  end

  # The guard asks about own properties; a bare assignment walks the prototype
  # chain. Declaring the var first is what keeps the two talking about the same
  # thing, so a setter the guest put on Object.prototype cannot take the value
  # while the guard reports a clean global.
  it "does not hand a var to a setter inherited from Object.prototype" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      globalThis.stolen = null;
      Object.defineProperty(Object.prototype, "CFG", {
        set(v) { stolen = v }, get() { return "FROMGETTER" }, configurable: true,
      });
    JS
    vm.instance_variable_set(:@_defined_variables, { "CFG" => :var })

    vm.define_var(:CFG, { "secret" => 1 })

    _(vm.eval_code("stolen")).must_be_nil
    _(vm.eval_code("JSON.stringify(CFG)")).must_equal %q({"secret":1})
  end
  # Every redefine consults the liveness check, and it read the `globalThis`
  # property while the guard above had moved to the real global. A decoy split
  # them: the check reported a property of the real global as a lexical
  # binding, the declaration that would have made one was skipped, and the
  # assignment wrote the property. A let on globalThis, which is the one thing
  # this form promises does not happen.
  it "keeps a let off a globalThis that has been pointed at a decoy" do
    vm = Quickjs::VM.new(timeout_msec: 60_000)
    vm.eval_code("globalThis.owned = 'guest'; globalThis = {};")
    vm.define_let(:warm, 1)
    busy = ::Thread.new do
      vm.eval_code("let s = 0; for (let i = 0; i < 60000000; i++) s += i; s")
    rescue StandardError
      nil
    end
    sleep 0.05
    begin
      vm.define_let(:owned, 1)
    rescue ThreadError
    end
    busy.join
    real = "(function () { return this })()"
    skip "the define was not refused in the window" unless vm.eval_code("typeof owned") == "string"

    vm.define_let(:owned, 42)

    _(vm.eval_code("owned")).must_equal 42
    _(vm.eval_code("#{real}.owned")).must_equal "guest"
  end

  # define_var(:globalThis, 1) is documented as succeeding, and it made every
  # later redefine throw `invalid 'in' operand` out of an internal probe.
  it "keeps working once globalThis is not an object at all" do
    vm = Quickjs::VM.new
    vm.define_var(:globalThis, 1)
    vm.define_let(:y, 1)
    vm.define_const(:k, 1)

    vm.define_let(:y, 2)

    _(vm.eval_code("y")).must_equal 2
    _ { vm.define_const(:k, 2) }.must_raise ArgumentError
  end

  it "refuses once Object has been replaced, and says why" do
    vm = Quickjs::VM.new
    vm.define_var(:Object, 1)

    err = _ { vm.define_var(:anything, 1) }.must_raise ArgumentError

    _(err.message).must_match(/globals/)
  end
end
