# frozen_string_literal: true

require_relative "test_helper"

describe "PolyfillIntl" do
  before do
    @options_to_enable_polyfill = { features: [::Quickjs::POLYFILL_INTL] }
  end

  describe "Intl.DateTimeFormat" do
    it "polyfill is provided by the feature" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'UTC', timeStyle: 'long', dateStyle: 'short' })"

      _(::Quickjs.eval_code(code)).must_match(/^03\/1(1|0)\/2025,\s/)
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '3/10/25, 3:00:00 PM UTC'
    end

    it "is a bit diff from common behavior for default options" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'America/Los_Angeles' })"

      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal '3/10/2025'
    end

    it "is a bit diff from common behavior for delimiter of time format" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'America/Los_Angeles', timeStyle: 'long', dateStyle: 'long' })"

      _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal 'March 10, 2025, 8:00:00 AM PDT'
    end

    # Timezones beyond UTC and America/Los_Angeles are available thanks to add-all-tz.js
    describe "with all timezones" do
      it "supports Asia/Tokyo timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Tokyo', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-01-01T00:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '1/1/25, 9:00:00 AM GMT+9'
      end

      it "supports Europe/London timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Europe/London', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-01-15T12:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '1/15/25, 12:00:00 PM GMT'
      end

      it "supports Pacific/Auckland timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Auckland', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-01-01T00:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '1/1/25, 1:00:00 PM GMT+13'
      end

      it "supports Africa/Nairobi timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Africa/Nairobi', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-06-15T00:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '6/15/25, 3:00:00 AM GMT+3'
      end
    end
  end

  describe "Intl.Locale" do
    it "polyfill is provided" do
      code = 'new Intl.Locale("ja-Jpan-JP-u-ca-japanese-hc-h12").toString()'

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal 'ja-Jpan-JP-u-ca-japanese-hc-h12'
    end
  end

  describe "Intl.PluralRules" do
    it "polyfill is provided" do
      code = 'new Intl.PluralRules("en-US").select(1);'

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal 'one'
    end
  end

  describe "Intl.NumberFormat" do
    it "polyfill is provided" do
      code = "new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(12345)"

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal '$12,345.00'
    end
  end
end

describe "PolyfillBlob" do
  before do
    @options = { features: [::Quickjs::POLYFILL_FILE] }
  end

  it "is not available without the polyfill" do
    _ { ::Quickjs.eval_code("new Blob()") }.must_raise Quickjs::ReferenceError
  end

  it "implicitly enables btoa and atob" do
    _(::Quickjs.eval_code("btoa('hello')", @options)).must_equal 'aGVsbG8='
    _(::Quickjs.eval_code("atob('aGVsbG8=')", @options)).must_equal 'hello'
  end

  describe "constructor" do
    it "creates an empty blob with no arguments" do
      _(::Quickjs.eval_code("new Blob().size", @options)).must_equal 0
    end

    it "creates a blob from string parts" do
      _(::Quickjs.eval_code("new Blob(['hello', ' ', 'world']).size", @options)).must_equal 11
    end

    it "creates a blob with type option" do
      _(::Quickjs.eval_code("new Blob([], { type: 'text/plain' }).type", @options)).must_equal 'text/plain'
    end

    it "normalizes type to lowercase" do
      _(::Quickjs.eval_code("new Blob([], { type: 'Text/Plain' }).type", @options)).must_equal 'text/plain'
    end

    it "rejects type with non-ASCII characters" do
      _(::Quickjs.eval_code("new Blob([], { type: 'text/plàin' }).type", @options)).must_equal ''
    end

    it "creates a blob from ArrayBuffer" do
      code = "const buf = new ArrayBuffer(4); new Uint8Array(buf).set([1,2,3,4]); new Blob([buf]).size"
      _(::Quickjs.eval_code(code, @options)).must_equal 4
    end

    it "creates a blob from Uint8Array" do
      code = "new Blob([new Uint8Array([72, 105])]).size"
      _(::Quickjs.eval_code(code, @options)).must_equal 2
    end

    it "creates a blob from mixed parts including another Blob" do
      code = <<~JS
        const b1 = new Blob(['hello']);
        const b2 = new Blob([b1, ' world']);
        await b2.text()
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello world'
    end

    it "throws TypeError for non-array argument" do
      _ { ::Quickjs.eval_code("new Blob('hello')", @options) }.must_raise Quickjs::TypeError
    end
  end

  describe "size and type" do
    it "returns correct size for multibyte UTF-8" do
      # "café" is 5 bytes in UTF-8 (é is 2 bytes)
      _(::Quickjs.eval_code("new Blob(['café']).size", @options)).must_equal 5
    end

    it "returns empty string type by default" do
      _(::Quickjs.eval_code("new Blob().type", @options)).must_equal ''
    end
  end

  describe "slice" do
    it "slices a blob" do
      code = "await new Blob(['hello world']).slice(0, 5).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello'
    end

    it "slices with negative start" do
      code = "await new Blob(['hello world']).slice(-5).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'world'
    end

    it "slices with content type" do
      code = "new Blob(['test']).slice(0, 4, 'text/plain').type"
      _(::Quickjs.eval_code(code, @options)).must_equal 'text/plain'
    end

    it "returns empty blob for out-of-range slice" do
      code = "new Blob(['hi']).slice(10, 20).size"
      _(::Quickjs.eval_code(code, @options)).must_equal 0
    end
  end

  describe "text" do
    it "returns text content" do
      code = "await new Blob(['hello']).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello'
    end

    it "handles multibyte characters" do
      code = "await new Blob(['日本語']).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal '日本語'
    end
  end

  describe "arrayBuffer" do
    it "returns an ArrayBuffer with correct length" do
      code = "const buf = await new Blob(['hi']).arrayBuffer(); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 2
    end

    it "returns correct bytes" do
      code = <<~JS
        const buf = await new Blob(['AB']).arrayBuffer();
        const arr = new Uint8Array(buf);
        [arr[0], arr[1]].join(',')
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal '65,66'
    end
  end

  describe "toString and toStringTag" do
    it "has correct toString" do
      _(::Quickjs.eval_code("new Blob().toString()", @options)).must_equal '[object Blob]'
    end

    it "has correct toStringTag" do
      _(::Quickjs.eval_code("Object.prototype.toString.call(new Blob())", @options)).must_equal '[object Blob]'
    end
  end
end

describe "PolyfillFile" do
  before do
    @options = { features: [::Quickjs::POLYFILL_FILE] }
  end

  it "is not available without the polyfill" do
    _ { ::Quickjs.eval_code("new File([], 'test.txt')") }.must_raise Quickjs::ReferenceError
  end

  describe "constructor" do
    it "creates a file with name" do
      _(::Quickjs.eval_code("new File(['hello'], 'test.txt').name", @options)).must_equal 'test.txt'
    end

    it "creates a file with content from parts" do
      code = "await new File(['hello', ' world'], 'test.txt').text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello world'
    end

    it "has correct size" do
      _(::Quickjs.eval_code("new File(['abc'], 'test.txt').size", @options)).must_equal 3
    end

    it "accepts type option" do
      _(::Quickjs.eval_code("new File([], 'test.txt', { type: 'text/plain' }).type", @options)).must_equal 'text/plain'
    end

    it "has lastModified defaulting to now" do
      code = <<~JS
        const before = Date.now();
        const f = new File([], 'test.txt');
        const after = Date.now();
        f.lastModified >= before && f.lastModified <= after
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "accepts custom lastModified" do
      _(::Quickjs.eval_code("new File([], 'test.txt', { lastModified: 1234567890 }).lastModified", @options)).must_equal 1234567890
    end

    it "throws TypeError with fewer than 2 arguments" do
      _ { ::Quickjs.eval_code("new File([])", @options) }.must_raise Quickjs::TypeError
    end
  end

  describe "inheritance from Blob" do
    it "is an instance of Blob" do
      _(::Quickjs.eval_code("new File([], 'test.txt') instanceof Blob", @options)).must_equal true
    end

    it "supports slice" do
      code = "await new File(['hello world'], 'test.txt').slice(0, 5).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello'
    end

    it "supports arrayBuffer" do
      code = "const buf = await new File(['AB'], 'test.txt').arrayBuffer(); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 2
    end
  end

  describe "toString and toStringTag" do
    it "has correct toString" do
      _(::Quickjs.eval_code("new File([], 'test.txt').toString()", @options)).must_equal '[object File]'
    end

    it "has correct toStringTag" do
      _(::Quickjs.eval_code("Object.prototype.toString.call(new File([], 'x'))", @options)).must_equal '[object File]'
    end
  end
end

describe "PolyfillFileReader" do
  before do
    @options = { features: [::Quickjs::POLYFILL_FILE] }
  end

  it "is not available without the polyfill" do
    _ { ::Quickjs.eval_code("new FileReader()") }.must_raise Quickjs::ReferenceError
  end

  describe "initial state" do
    it "starts with EMPTY readyState" do
      _(::Quickjs.eval_code("new FileReader().readyState", @options)).must_equal 0
    end

    it "starts with null result" do
      assert_nil ::Quickjs.eval_code("new FileReader().result", @options)
    end

    it "starts with null error" do
      assert_nil ::Quickjs.eval_code("new FileReader().error", @options)
    end

    it "exposes state constants" do
      code = <<~JS
        const r = new FileReader();
        [FileReader.EMPTY, FileReader.LOADING, FileReader.DONE, r.EMPTY, r.LOADING, r.DONE].join(',')
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal '0,1,2,0,1,2'
    end
  end

  describe "readAsText" do
    it "reads blob content as text" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.readAsText(new Blob(['hello world']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello world'
    end

    it "reads File content as text" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.readAsText(new File(['file content'], 'test.txt'));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'file content'
    end

    it "handles multibyte UTF-8" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.readAsText(new Blob(['日本語']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal '日本語'
    end

    it "sets readyState to DONE after reading" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.readyState);
          reader.readAsText(new Blob(['test']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 2
    end

    it "sets readyState to LOADING synchronously" do
      code = <<~JS
        const reader = new FileReader();
        reader.readAsText(new Blob(['test']));
        reader.readyState
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 1
    end
  end

  describe "events" do
    it "fires loadstart, progress, load, loadend in order" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          const events = [];
          reader.onloadstart = () => events.push('loadstart');
          reader.onprogress = () => events.push('progress');
          reader.onload = () => events.push('load');
          reader.onloadend = () => { events.push('loadend'); resolve(events.join(',')); };
          reader.readAsText(new Blob(['test']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'loadstart,progress,load,loadend'
    end

    it "supports addEventListener" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.addEventListener('load', () => resolve(reader.result));
          reader.readAsText(new Blob(['via addEventListener']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'via addEventListener'
    end

    it "supports removeEventListener" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          const removed = () => resolve('should not fire');
          reader.addEventListener('load', removed);
          reader.removeEventListener('load', removed);
          reader.onload = () => resolve('correct');
          reader.readAsText(new Blob(['test']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'correct'
    end

    it "provides event.target pointing to the reader" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = (e) => resolve(e.target === reader);
          reader.readAsText(new Blob(['test']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end
  end

  describe "readAsArrayBuffer" do
    it "reads blob content as ArrayBuffer" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => {
            const arr = new Uint8Array(reader.result);
            resolve([arr[0], arr[1]].join(','));
          };
          reader.readAsArrayBuffer(new Blob(['AB']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal '65,66'
    end

    it "returns ArrayBuffer with correct byteLength" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result.byteLength);
          reader.readAsArrayBuffer(new Blob(['hello']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 5
    end
  end

  describe "readAsDataURL" do
    it "reads blob as data URL with type" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.readAsDataURL(new Blob(['hello'], { type: 'text/plain' }));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'data:text/plain;base64,aGVsbG8='
    end

    it "uses application/octet-stream for blobs without type" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result.startsWith('data:application/octet-stream;base64,'));
          reader.readAsDataURL(new Blob(['test']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "encodes binary data correctly" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.readAsDataURL(new Blob([new Uint8Array([0, 1, 2, 255])], { type: 'application/octet-stream' }));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'data:application/octet-stream;base64,AAEC/w=='
    end

    it "encodes empty blob" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.readAsDataURL(new Blob([], { type: 'text/plain' }));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'data:text/plain;base64,'
    end
  end

  describe "readAsBinaryString" do
    it "reads blob as binary string" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.readAsBinaryString(new Blob(['AB']));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'AB'
    end

    it "returns raw bytes for binary data" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onload = () => {
            const codes = [];
            for (let i = 0; i < reader.result.length; i++) {
              codes.push(reader.result.charCodeAt(i));
            }
            resolve(codes.join(','));
          };
          reader.readAsBinaryString(new Blob([new Uint8Array([0, 127, 128, 255])]));
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal '0,127,128,255'
    end
  end

  describe "error handling" do
    it "throws TypeError for non-Blob argument" do
      code = <<~JS
        const reader = new FileReader();
        reader.readAsText('not a blob');
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::TypeError
    end

    it "throws InvalidStateError when already loading" do
      code = <<~JS
        const reader = new FileReader();
        reader.readAsText(new Blob(['test']));
        reader.readAsText(new Blob(['test2']));
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end
  end

  describe "abort" do
    it "fires abort and loadend events" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          const events = [];
          reader.onabort = () => events.push('abort');
          reader.onloadend = () => { events.push('loadend'); resolve(events.join(',')); };
          reader.readAsText(new Blob(['test']));
          reader.abort();
        })
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'abort,loadend'
    end

    it "sets result to null after abort" do
      code = <<~JS
        await new Promise(resolve => {
          const reader = new FileReader();
          reader.onloadend = () => resolve(reader.result);
          reader.readAsText(new Blob(['test']));
          reader.abort();
        })
      JS
      assert_nil ::Quickjs.eval_code(code, @options)
    end
  end

  describe "toString and toStringTag" do
    it "has correct toString" do
      _(::Quickjs.eval_code("new FileReader().toString()", @options)).must_equal '[object FileReader]'
    end

    it "has correct toStringTag" do
      _(::Quickjs.eval_code("Object.prototype.toString.call(new FileReader())", @options)).must_equal '[object FileReader]'
    end
  end
end

describe "PolyfillHtmlBase64" do
  before do
    @options = { features: [::Quickjs::POLYFILL_HTML_BASE64] }
  end

  it "is not available without the polyfill" do
    _ { ::Quickjs.eval_code("btoa('hello')") }.must_raise Quickjs::ReferenceError
    _ { ::Quickjs.eval_code("atob('aGVsbG8=')") }.must_raise Quickjs::ReferenceError
  end

  describe "btoa" do
    it "encodes ASCII string" do
      _(::Quickjs.eval_code("btoa('hello')", @options)).must_equal 'aGVsbG8='
    end

    it "encodes empty string" do
      _(::Quickjs.eval_code("btoa('')", @options)).must_equal ''
    end

    it "encodes string with padding" do
      _(::Quickjs.eval_code("btoa('a')", @options)).must_equal 'YQ=='
      _(::Quickjs.eval_code("btoa('ab')", @options)).must_equal 'YWI='
      _(::Quickjs.eval_code("btoa('abc')", @options)).must_equal 'YWJj'
    end

    it "encodes Latin1 characters" do
      _(::Quickjs.eval_code("btoa('\\xFF\\xFE')", @options)).must_equal '//4='
    end

    it "throws on multi-byte characters" do
      error = _ { ::Quickjs.eval_code("btoa('こんにちは')", @options) }.must_raise Quickjs::RuntimeError
      _(error.message).must_include 'Latin1'
    end

    it "throws with no arguments" do
      _ { ::Quickjs.eval_code("btoa()", @options) }.must_raise Quickjs::TypeError
    end
  end

  describe "atob" do
    it "decodes base64 string" do
      _(::Quickjs.eval_code("atob('aGVsbG8=')", @options)).must_equal 'hello'
    end

    it "decodes empty string" do
      _(::Quickjs.eval_code("atob('')", @options)).must_equal ''
    end

    it "decodes base64 without padding" do
      _(::Quickjs.eval_code("atob('YWJj')", @options)).must_equal 'abc'
    end

    it "throws on invalid base64" do
      _ { ::Quickjs.eval_code("atob('!')", @options) }.must_raise Quickjs::RuntimeError
    end

    it "throws with no arguments" do
      _ { ::Quickjs.eval_code("atob()", @options) }.must_raise Quickjs::TypeError
    end
  end

  describe "round-trip" do
    it "round-trips ASCII strings" do
      _(::Quickjs.eval_code("atob(btoa('Hello, World!'))", @options)).must_equal 'Hello, World!'
    end

    it "round-trips binary data" do
      code = <<~JS
        const binary = String.fromCharCode(0, 1, 2, 128, 255);
        atob(btoa(binary)) === binary ? 'ok' : 'fail';
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'ok'
    end
  end
end
