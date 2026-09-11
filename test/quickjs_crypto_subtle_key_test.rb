# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
require "open3"

describe "crypto.subtle key management" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  describe "generateKey" do
    it "returns a CryptoKey with correct properties for AES-GCM 256" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt", "decrypt"]);
        ({ type: key.type, extractable: key.extractable, name: key.algorithm.name, length: key.algorithm.length, usages: key.usages })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["type"]).must_equal "secret"
      _(result["extractable"]).must_equal true
      _(result["name"]).must_equal "AES-GCM"
      _(result["length"]).must_equal 256
      _(result["usages"]).must_equal ["encrypt", "decrypt"]
    end

    it "supports AES-CBC and AES-CTR" do
      %w[AES-CBC AES-CTR].each do |name|
        code = "const key = await crypto.subtle.generateKey({name: '#{name}', length: 128}, false, ['encrypt']); key.algorithm.name"
        _(::Quickjs.eval_code(code, @options)).must_equal name
      end
    end

    it "supports 128 and 192 bit key lengths" do
      [128, 192].each do |len|
        code = "const key = await crypto.subtle.generateKey({name: 'AES-GCM', length: #{len}}, true, ['encrypt']); key.algorithm.length"
        _(::Quickjs.eval_code(code, @options)).must_equal len
      end
    end

    it "rejects unsupported algorithm" do
      code = "await crypto.subtle.generateKey({name: 'RSA-PSS', length: 2048}, true, ['sign'])"
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end

    it "rejects invalid key length" do
      code = "await crypto.subtle.generateKey({name: 'AES-GCM', length: 512}, true, ['encrypt'])"
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end

    it "rb_object_id is not enumerable (not included in JSON.stringify)" do
      code = "const key = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, true, ['encrypt']); Object.keys(key).includes('rb_object_id')"
      _(::Quickjs.eval_code(code, @options)).must_equal false
    end
  end

  describe "exportKey" do
    it "exports a raw AES-GCM key with correct byte length" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt", "decrypt"]);
        const raw = await crypto.subtle.exportKey("raw", key);
        raw.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "exports 128-bit key as 16 bytes" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 128}, true, ["encrypt"]);
        const raw = await crypto.subtle.exportKey("raw", key);
        raw.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 16
    end

    it "rejects export of non-extractable key" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, false, ["encrypt"]);
        await crypto.subtle.exportKey("raw", key)
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end
  end

  describe "importKey" do
    it "imports a raw key and returns correct properties" do
      code = <<~JS
        const raw = new Uint8Array(32);
        const key = await crypto.subtle.importKey("raw", raw, {name: "AES-GCM"}, true, ["encrypt", "decrypt"]);
        ({ type: key.type, name: key.algorithm.name, length: key.algorithm.length })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["type"]).must_equal "secret"
      _(result["name"]).must_equal "AES-GCM"
      _(result["length"]).must_equal 256
    end

    it "round-trips key data through exportKey → importKey → exportKey" do
      code = <<~JS
        const key1 = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt"]);
        const raw1 = await crypto.subtle.exportKey("raw", key1);
        const key2 = await crypto.subtle.importKey("raw", raw1, {name: "AES-GCM"}, true, ["encrypt"]);
        const raw2 = await crypto.subtle.exportKey("raw", key2);
        const a = new Uint8Array(raw1);
        const b = new Uint8Array(raw2);
        a.every((v, i) => v === b[i])
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "rejects unsupported format" do
      code = <<~JS
        const raw = new Uint8Array(32);
        await crypto.subtle.importKey("jwk", raw, {name: "AES-GCM"}, true, ["encrypt"])
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end

    it "rejects invalid key length" do
      code = <<~JS
        const raw = new Uint8Array(10);
        await crypto.subtle.importKey("raw", raw, {name: "AES-GCM"}, true, ["encrypt"])
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end
  end
    it "cannot be recovered by scanning the handle space" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.eval_code("globalThis.k = await crypto.subtle.generateKey({name: 'HMAC', hash: 'SHA-256'}, false, ['sign', 'verify'])")
      _(vm.eval_code("(await crypto.subtle.sign('HMAC', globalThis.k, new Uint8Array([1, 2, 3]))).byteLength")).must_equal 32
      vm.eval_code('delete globalThis.k; 1')

      found = vm.eval_code(<<~JS)
        let found = 'none';
        for (let i = 1; i < 5000; i++) {
          try {
            const s = await crypto.subtle.sign('HMAC', {rb_object_id: i}, new Uint8Array([1, 2, 3]));
            if (s) { found = 'recovered at ' + i; break }
          } catch (e) {}
        }
        found
      JS

      _(found).must_equal 'none'
    ensure
      vm&.dispose!
    end
    # Both writers below define rather than assign, so a getter the guest puts
    # on a prototype cannot answer in their place.
    it "does not let a guest's Error.prototype answer for a rejection" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO])
      vm.eval_code(<<~JS)
        Object.defineProperty(Error.prototype, 'message', { set(v) {}, get() { return 'ghost' }, configurable: true });
      JS

      message = vm.eval_code(<<~JS)
        let m = 'none';
        try { await crypto.subtle.importKey('raw', new Uint8Array(16), { name: 'NOPE' }, true, ['sign']) }
        catch (e) { m = e.message }
        m
      JS

      _(message).must_include 'NOPE'
    ensure
      vm&.dispose!
    end

    it "does not let a guest's Object.prototype describe a key's algorithm" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.eval_code(<<~JS)
        Object.defineProperty(Object.prototype, 'name',   { set() {}, get() { return 'POISON' }, configurable: true });
        Object.defineProperty(Object.prototype, 'length', { set() {}, get() { return 4096 }, configurable: true });
      JS

      described = vm.eval_code(<<~JS)
        const k = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['encrypt']);
        [k.algorithm.name, k.algorithm.length, Object.getOwnPropertyNames(k.algorithm).sort().join(',')].join('|')
      JS

      _(described).must_equal 'AES-GCM|128|length,name'
    ensure
      vm&.dispose!
    end

    # A key that could not be built is a rejection, never a resolution carrying
    # the exception sentinel: typeof reads "unknown" for that and the guest can
    # neither name it nor tell it apart from a key.
    # Describing a key runs StringValueCStr, which raises on a non-String, out
    # of a JSCFunction. Nothing is registered until the description is finished,
    # so a raise there cannot leave a row anchoring the key.
    # The handle read is own data, so an accessor on Object.prototype cannot
    # answer it: a bare object carrying no handle is not a key, whatever the
    # prototype says.
    it "does not let an inherited handle sign with a key it never carried" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])

      outcome = vm.eval_code(<<~JS)
        const k = await crypto.subtle.generateKey({ name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
        globalThis.H = k.rb_object_id;
        Object.defineProperty(Object.prototype, 'rb_object_id', { get() { return globalThis.H }, configurable: true });
        let o = 'none';
        try { await crypto.subtle.sign('HMAC', {}, new Uint8Array([1, 2, 3])); o = 'signed' }
        catch (e) { o = 'refused' }
        o
      JS

      _(outcome).must_equal 'refused'
    ensure
      vm&.dispose!
    end

    # A usages member that is not a String converts through to_str, which runs
    # Ruby and can raise. It is converted before anything is drawn or
    # allocated, so the raise cannot orphan a row.
    it "anchors nothing when a usages member raises on conversion" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      late = Class.new { def to_str = raise(ArgumentError, 'late') }
      malformed = Class.new(::Quickjs::CryptoKey)

      ::Quickjs::SubtleCrypto.singleton_class.alias_method(:generate_key_before_stub, :generate_key)
      ::Quickjs::SubtleCrypto.define_singleton_method(:generate_key) do |_algo, _extractable, _usages|
        malformed.allocate.tap do |k|
          k.instance_variable_set(:@key_data, 'x' * 16)
          k.instance_variable_set(:@type, 'secret')
          k.instance_variable_set(:@extractable, false)
          k.instance_variable_set(:@algorithm, { 'name' => 'AES-GCM' })
          k.instance_variable_set(:@usages, [late.new])
        end
      end

      20.times do
        vm.eval_code("try { await crypto.subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['encrypt']) } catch (e) {} 1") rescue nil
      end

      GC.start(full_mark: true, immediate_sweep: true)
      before = ObjectSpace.each_object(malformed).count
      vm.dispose!
      GC.start(full_mark: true, immediate_sweep: true)

      _(before - ObjectSpace.each_object(malformed).count).must_equal 0
    ensure
      ::Quickjs::SubtleCrypto.singleton_class.alias_method(:generate_key, :generate_key_before_stub)
      ::Quickjs::SubtleCrypto.singleton_class.remove_method(:generate_key_before_stub)
      vm&.dispose! unless vm&.disposed?
    end

    it "anchors nothing when describing the key raises" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      malformed = Class.new(::Quickjs::CryptoKey) do
        def type = 42
      end

      ::Quickjs::SubtleCrypto.singleton_class.alias_method(:generate_key_before_stub, :generate_key)
      ::Quickjs::SubtleCrypto.define_singleton_method(:generate_key) do |_algo, _extractable, _usages|
        malformed.new('secret', type: 'secret', extractable: false, algorithm: { 'name' => 'AES-GCM' }, usages: ['encrypt'])
      rescue ArgumentError
        malformed.allocate.tap do |k|
          k.instance_variable_set(:@key_data, 'x' * 16)
          k.instance_variable_set(:@extractable, false)
          k.instance_variable_set(:@algorithm, { 'name' => 'AES-GCM' })
          k.instance_variable_set(:@usages, ['encrypt'])
        end
      end

      20.times do
        vm.eval_code("try { await crypto.subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['encrypt']) } catch (e) {} 1") rescue nil
      end

      GC.start(full_mark: true, immediate_sweep: true)
      before = ObjectSpace.each_object(malformed).count
      vm.dispose!
      GC.start(full_mark: true, immediate_sweep: true)

      _(before - ObjectSpace.each_object(malformed).count).must_equal 0
    ensure
      ::Quickjs::SubtleCrypto.singleton_class.alias_method(:generate_key, :generate_key_before_stub)
      ::Quickjs::SubtleCrypto.singleton_class.remove_method(:generate_key_before_stub)
      vm&.dispose! unless vm&.disposed?
    end

    it "rejects rather than resolving with a key it could not build" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.define_function(:boom) { raise IOError, 'host' }

      SecureRandom.singleton_class.alias_method(:random_number_before_stub, :random_number)
      SecureRandom.define_singleton_method(:random_number) { |_limit| 4 }
      # Takes the one handle that source can draw, so the key cannot have one.
      vm.eval_code('try { boom() } catch (e) {} 1')

      single = vm.eval_code(<<~JS)
        let o = 'none';
        try { const k = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 128 }, true, ['encrypt']); o = 'resolved ' + typeof k }
        catch (e) { o = 'rejected' }
        o
      JS

      _(single).must_equal 'rejected'
    ensure
      SecureRandom.singleton_class.alias_method(:random_number, :random_number_before_stub)
      SecureRandom.singleton_class.remove_method(:random_number_before_stub)
      vm&.dispose!
    end

    it "rejects rather than resolving with half a key pair" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.define_function(:boom) { raise IOError, 'host' }

      SecureRandom.singleton_class.alias_method(:random_number_before_stub, :random_number)
      SecureRandom.define_singleton_method(:random_number) { |_limit| 4 }
      vm.eval_code('try { boom() } catch (e) {} 1')

      pair = vm.eval_code(<<~JS)
        let o = 'none';
        try { const p = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']); o = 'resolved ' + typeof p.privateKey }
        catch (e) { o = 'rejected' }
        o
      JS

      _(pair).must_equal 'rejected'
    ensure
      SecureRandom.singleton_class.alias_method(:random_number, :random_number_before_stub)
      SecureRandom.singleton_class.remove_method(:random_number_before_stub)
      vm&.dispose!
    end

    it "does not let a guest's Array.prototype answer for a key's usages" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      # An index property, which costs the fast array path and sends the
      # element write through the chain like a named one.
      vm.eval_code("Object.defineProperty(Array.prototype, 0, { set() {}, get() { return 'decrypt' }, configurable: true }); 1")

      described = vm.eval_code(<<~JS)
        const k = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['encrypt']);
        [k.usages.length, k.usages[0], JSON.stringify(k.usages)].join('|')
      JS

      _(described).must_equal '1|encrypt|["encrypt"]'
    ensure
      vm&.dispose!
    end

    it "does not let a guest's Object.prototype stand in for a private key" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.eval_code(<<~JS)
        Object.defineProperty(Object.prototype, 'privateKey', { set() {}, get() { return 'POISON' }, configurable: true });
      JS

      described = vm.eval_code(<<~JS)
        const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
        [typeof pair.privateKey, Object.getOwnPropertyNames(pair).sort().join(',')].join('|')
      JS

      _(described).must_equal 'object|privateKey,publicKey'
    ensure
      vm&.dispose!
    end

    it "does not let a guest's Object.prototype describe a key we handed out" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO])
      vm.eval_code(<<~JS)
        for (const name of ['type', 'extractable', 'algorithm', 'usages']) {
          Object.defineProperty(Object.prototype, name, { get() { return 'POISON' }, configurable: true });
        }
      JS

      described = vm.eval_code(<<~JS)
        const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt']);
        [key.type, key.extractable, JSON.stringify(key.usages), key.algorithm.name].join('|')
      JS

      _(described).must_equal 'secret|false|["encrypt"]|AES-GCM'
    ensure
      vm&.dispose!
    end
    # The handle is read off whatever the guest passes as the key argument, so
    # unlike the File proxy's closure-captured one it is the guest's to choose.
    # An id belonging to another entry used to reach the operation as a key.
    it "refuses an id that belongs to something else in the table" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.define_function(:boom) { raise ArgumentError, 'host' }
      vm.eval_code("globalThis.id = null; try { boom() } catch (e) { globalThis.id = e.rb_object_id }")
      # Without this the id could go undefined and the pre-existing handle <= 0
      # check would produce the same message, leaving the test guarding nothing.
      _(vm.eval_code("typeof globalThis.id")).must_equal 'number'

      error = _ { vm.eval_code("await crypto.subtle.sign('HMAC', {rb_object_id: globalThis.id}, new Uint8Array([1, 2, 3]))") }
        .must_raise Quickjs::TypeError
      _(error.message).must_match(/invalid CryptoKey/)
    ensure
      vm&.dispose!
    end
    # Guards against re-introducing a cache rather than pinning the lookup as
    # it stands: a class held only by a constant table is movable, so a C
    # static would keep an address the collector has since handed on. Passes
    # either way today, since nothing is cached.
    it "keeps working across a compaction" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.eval_code("globalThis.k = await crypto.subtle.generateKey({name: 'HMAC', hash: 'SHA-256'}, true, ['sign', 'verify'])")
      sign = "(await crypto.subtle.sign('HMAC', globalThis.k, new Uint8Array([1, 2, 3]))).byteLength"
      _(vm.eval_code(sign)).must_equal 32

      5.times { GC.compact }

      _(vm.eval_code(sign)).must_equal 32
    ensure
      vm&.dispose!
    end
    # The lookup runs inside a QuickJS native callback with no rb_protect
    # between it and the interpreter, so it must answer rather than raise when
    # the Ruby layer that defines the class has not been loaded. Requiring the
    # extension on its own is enough to get there, and a NameError from here
    # longjmps through QuickJS's frames past the JS values they still hold.
    # rb_const_defined_at answers true for a registered autoload, and the
    # rb_const_get after it would run the autoload body from inside the
    # callback, which is the raise this lookup exists to not make.
    it "answers invalid CryptoKey rather than running an autoload" do
      dir = Dir.mktmpdir('quickjs-autoload')
      body = File.join(dir, 'raising_autoload.rb')
      File.write(body, "raise 'autoload body'")

      script = <<~RUBY
        require "quickjs"
        Quickjs.send(:remove_const, :CryptoKey)
        Quickjs.autoload(:CryptoKey, #{body.inspect})

        vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO])
        vm.define_function(:boom) { raise ArgumentError, 'host' }
        vm.eval_code("globalThis.id = null; try { boom() } catch (e) { globalThis.id = e.rb_object_id }")
        abort "no id was planted" unless vm.eval_code("typeof globalThis.id") == 'number'
        begin
          vm.eval_code('await crypto.subtle.sign("HMAC", {rb_object_id: globalThis.id}, new Uint8Array([1]))')
          puts "no raise"
        rescue Exception => e
          puts "\#{e.class}: \#{e.message}"
        end
      RUBY

      lib = File.expand_path('../lib', __dir__)
      out, status = Open3.capture2e(RbConfig.ruby, '-I', lib, '-e', script)

      _(out).must_match(/Quickjs::TypeError: .*invalid CryptoKey/)
      _(status).must_be :success?
    ensure
      FileUtils.remove_entry(dir) if dir
    end
    it "answers invalid CryptoKey when Quickjs::CryptoKey is not defined" do
      script = <<~RUBY
        require "quickjs/quickjsrb"
        abort "CryptoKey should not be loaded" if Quickjs.const_defined?(:CryptoKey)
        vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO])
        # A real entry rather than a made-up id: 1 is in no table, so the nil
        # hash hit alone would satisfy the callers and the class lookup would
        # never be reached.
        vm.define_function(:boom) { raise ArgumentError, 'host' }
        vm.eval_code("globalThis.id = null; try { boom() } catch (e) { globalThis.id = e.rb_object_id }")
        abort "no id was planted" unless vm.eval_code("typeof globalThis.id") == 'number'
        begin
          vm.eval_code('await crypto.subtle.sign("HMAC", {rb_object_id: globalThis.id}, new Uint8Array([1]))')
          puts "no raise"
        rescue Exception => e
          puts "\#{e.class}: \#{e.message}"
        end
      RUBY

      lib = File.expand_path('../lib', __dir__)
      out, status = Open3.capture2e(RbConfig.ruby, '-I', lib, '-e', script)
      # Asserted before the exit status so the abort guard's own message, or a
      # LoadError, is what a failure reports rather than "expected success?".
      _(out).must_match(/Quickjs::TypeError: .*invalid CryptoKey/)
      _(status).must_be :success?
    end
    # Every property of the algorithm and of the key is a read the guest can
    # answer with a getter, and a getter that reaches a bridge parks the host's
    # exception on the way out. A reader that skips the throw without draining
    # it leaves one behind per read.
    it "does not park a host exception raised by a getter it reads" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      # cause: nil keeps the count independent of #126, where a raise chains to
      # whatever the bridge left in $! and holds that chain reachable from
      # errinfo however little the VM parked. It is belt and braces for this
      # shape, whose calls are awaited and see $! nil in the block; it is
      # load-bearing for a repeated synchronous `try { boom() } catch {}`.
      vm.define_function(:boom) { raise IOError.new('host'), cause: nil }
      vm.eval_code("globalThis.k = await crypto.subtle.generateKey({name: 'HMAC', hash: 'SHA-256'}, true, ['sign', 'verify'])")

      shapes = [
        "await crypto.subtle.sign({get name() { boom() }}, globalThis.k, new Uint8Array([1]))",
        "await crypto.subtle.sign('HMAC', {get rb_object_id() { boom() }}, new Uint8Array([1]))",
        "await crypto.subtle.importKey('raw', new Uint8Array(16), {name: 'HMAC', get hash() { boom() }}, true, ['sign'])",
        "await crypto.subtle.generateKey({name: 'AES-GCM', get length() { boom() }}, true, ['encrypt'])",
        "await crypto.subtle.encrypt({name: 'AES-GCM', get iv() { boom() }}, globalThis.k, new Uint8Array([1]))",
        # keyUsages is read the same way the algorithm is.
        "await crypto.subtle.generateKey({name: 'HMAC', hash: 'SHA-256'}, true, {get length() { boom() }})",
        "await crypto.subtle.generateKey({name: 'HMAC', hash: 'SHA-256'}, true, {length: 1, get 0() { boom() }})",
        # A throw whose own rb_object_id getter reaches the bridge, so draining
        # it is itself a read that can park one.
        "const mk = () => { const o = {}; Object.defineProperty(o, 'rb_object_id', {get() { boom() }}); return o };" \
          "const bad = {}; Object.defineProperty(bad, 'rb_object_id', {get() { throw mk() }});" \
          "await crypto.subtle.sign('HMAC', bad, new Uint8Array([1]))",
      ]
      shapes.each { |js| 20.times { vm.eval_code("try { #{js} } catch (e) {}") } }

      GC.start(full_mark: true, immediate_sweep: true)
      before = ObjectSpace.each_object(IOError).count
      vm.dispose!
      GC.start(full_mark: true, immediate_sweep: true)

      _(before - ObjectSpace.each_object(IOError).count).must_equal 0
    ensure
      vm&.dispose! unless vm&.disposed?
    end
    # The drain drops the throw, so nothing will carry the host exception out
    # and its anchor would only be a leak. A guest that kept its own reference
    # can still rethrow the object; what it has then is the message, not the
    # class. j_rethrow_the_guests_own makes the opposite trade because it hands
    # the throw back rather than dropping it.
    it "keeps the message but not the class of an error the guest saved" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      vm.define_function(:boom) { raise ArgumentError, 'host secret' }
      vm.eval_code("globalThis.k = await crypto.subtle.generateKey({name: 'HMAC', hash: 'SHA-256'}, true, ['sign', 'verify'])")
      vm.eval_code(<<~JS)
        globalThis.saved = null;
        try {
          await crypto.subtle.sign({name: 'HMAC', get length() { try { boom() } catch (e) { saved = e; throw e } }}, globalThis.k, new Uint8Array([1]));
        } catch (e) {}
        1
      JS

      error = _ { vm.eval_code('throw globalThis.saved') }.must_raise Quickjs::RuntimeError

      _(error.message).must_equal 'host secret'
      _(error).wont_be_kind_of ArgumentError
    ensure
      vm&.dispose!
    end
    # to_js_value has no case for Quickjs::CryptoKey, so a key handed back to
    # JS converts by way of inspect. With the bytes in that string a guest
    # reads a key generated extractable: false straight out of any pass-through
    # host function, which exportKey refuses one call away.
    it "does not put key material in the string a guest gets back" do
      vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_CRYPTO])
      host_key = nil
      vm.define_function(:echo) { |k| host_key = k; k }
      vm.eval_code("globalThis.k = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, false, ['encrypt', 'decrypt'])")

      seen = vm.eval_code("echo(globalThis.k)").to_s
      bytes = host_key.key_data.to_s

      _(bytes.bytesize).must_equal 32
      _(seen).wont_include bytes
      _(seen).must_include '[FILTERED]'
      # The parts that are not the secret still describe the key.
      _(seen).must_include 'AES-GCM'
      _(seen).must_include 'extractable=false'
    ensure
      vm&.dispose!
    end
end
