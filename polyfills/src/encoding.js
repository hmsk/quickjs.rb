// WHATWG TextEncoder/TextDecoder polyfill for QuickJS
// Spec: https://encoding.spec.whatwg.org/

class TextEncoder {
  get encoding() {
    return "utf-8";
  }

  encode(input = "") {
    const str = String(input);
    const bytes = [];
    for (let i = 0; i < str.length; i++) {
      let code = str.charCodeAt(i);

      if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
        const next = str.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = (code - 0xd800) * 0x400 + (next - 0xdc00) + 0x10000;
          i++;
        }
      }

      if (code <= 0x7f) {
        bytes.push(code);
      } else if (code <= 0x7ff) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code <= 0xffff) {
        bytes.push(
          0xe0 | (code >> 12),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      } else {
        bytes.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return new Uint8Array(bytes);
  }

  encodeInto(source, destination) {
    const str = String(source);
    let read = 0;
    let written = 0;

    for (let i = 0; i < str.length; i++) {
      let code = str.charCodeAt(i);

      if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
        const next = str.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          if (written + 4 > destination.length) break;
          code = (code - 0xd800) * 0x400 + (next - 0xdc00) + 0x10000;
          destination[written++] = 0xf0 | (code >> 18);
          destination[written++] = 0x80 | ((code >> 12) & 0x3f);
          destination[written++] = 0x80 | ((code >> 6) & 0x3f);
          destination[written++] = 0x80 | (code & 0x3f);
          read += 2;
          i++;
          continue;
        }
      }

      let byteCount;
      if (code <= 0x7f) byteCount = 1;
      else if (code <= 0x7ff) byteCount = 2;
      else byteCount = 3;

      if (written + byteCount > destination.length) break;

      if (byteCount === 1) {
        destination[written++] = code;
      } else if (byteCount === 2) {
        destination[written++] = 0xc0 | (code >> 6);
        destination[written++] = 0x80 | (code & 0x3f);
      } else {
        destination[written++] = 0xe0 | (code >> 12);
        destination[written++] = 0x80 | ((code >> 6) & 0x3f);
        destination[written++] = 0x80 | (code & 0x3f);
      }
      read++;
    }

    return { read, written };
  }
}

const UTF8_LABELS = [
  "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8",
  "utf-8", "utf8", "x-unicode20utf8",
];

function normalizeEncodingLabel(label) {
  const normalized = label.trim().toLowerCase();
  if (UTF8_LABELS.includes(normalized)) return "utf-8";
  return null;
}

class TextDecoder {
  #encoding;
  #fatal;
  #ignoreBOM;

  constructor(label = "utf-8", options = {}) {
    const normalized = normalizeEncodingLabel(String(label));
    if (!normalized) {
      throw new RangeError(`The "${label}" encoding is not supported.`);
    }
    this.#encoding = normalized;
    this.#fatal = Boolean(options.fatal);
    this.#ignoreBOM = Boolean(options.ignoreBOM);
  }

  get encoding() {
    return this.#encoding;
  }

  get fatal() {
    return this.#fatal;
  }

  get ignoreBOM() {
    return this.#ignoreBOM;
  }

  decode(input, options = {}) {
    if (input === undefined || input === null) return "";

    let bytes;
    if (input instanceof ArrayBuffer) {
      bytes = new Uint8Array(input);
    } else if (ArrayBuffer.isView(input)) {
      bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    } else {
      throw new TypeError(
        "The provided value is not of type '(ArrayBuffer or ArrayBufferView)'"
      );
    }

    let start = 0;
    if (
      !this.#ignoreBOM &&
      bytes.length >= 3 &&
      bytes[0] === 0xef &&
      bytes[1] === 0xbb &&
      bytes[2] === 0xbf
    ) {
      start = 3;
    }

    return decodeUTF8(bytes, start, this.#fatal);
  }
}

function decodeUTF8(bytes, start, fatal) {
  let str = "";
  let i = start;
  while (i < bytes.length) {
    const b = bytes[i];
    let code, byteLen;

    if (b <= 0x7f) {
      code = b;
      byteLen = 1;
    } else if ((b & 0xe0) === 0xc0) {
      if (i + 1 >= bytes.length || (bytes[i + 1] & 0xc0) !== 0x80) {
        if (fatal) throw new TypeError("The encoded data was not valid.");
        str += "\ufffd";
        i++;
        continue;
      }
      code = ((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
      byteLen = 2;
    } else if ((b & 0xf0) === 0xe0) {
      if (
        i + 2 >= bytes.length ||
        (bytes[i + 1] & 0xc0) !== 0x80 ||
        (bytes[i + 2] & 0xc0) !== 0x80
      ) {
        if (fatal) throw new TypeError("The encoded data was not valid.");
        str += "\ufffd";
        i++;
        continue;
      }
      code =
        ((b & 0x0f) << 12) |
        ((bytes[i + 1] & 0x3f) << 6) |
        (bytes[i + 2] & 0x3f);
      byteLen = 3;
    } else if ((b & 0xf8) === 0xf0) {
      if (
        i + 3 >= bytes.length ||
        (bytes[i + 1] & 0xc0) !== 0x80 ||
        (bytes[i + 2] & 0xc0) !== 0x80 ||
        (bytes[i + 3] & 0xc0) !== 0x80
      ) {
        if (fatal) throw new TypeError("The encoded data was not valid.");
        str += "\ufffd";
        i++;
        continue;
      }
      code =
        ((b & 0x07) << 18) |
        ((bytes[i + 1] & 0x3f) << 12) |
        ((bytes[i + 2] & 0x3f) << 6) |
        (bytes[i + 3] & 0x3f);
      byteLen = 4;
    } else {
      if (fatal) throw new TypeError("The encoded data was not valid.");
      str += "\ufffd";
      i++;
      continue;
    }

    if (code <= 0xffff) {
      str += String.fromCharCode(code);
    } else {
      code -= 0x10000;
      str += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    }
    i += byteLen;
  }
  return str;
}

globalThis.TextEncoder = TextEncoder;
globalThis.TextDecoder = TextDecoder;
