// W3C Blob polyfill for QuickJS
// Spec: https://www.w3.org/TR/FileAPI/#blob-section

class Blob {
  #bytes;
  #type;

  constructor(blobParts, options) {
    this.#type = normalizeType(options?.type ?? "");

    if (!blobParts) {
      this.#bytes = new Uint8Array(0);
      return;
    }

    if (!Array.isArray(blobParts)) {
      throw new TypeError(
        "Failed to construct 'Blob': The provided value cannot be converted to a sequence."
      );
    }

    const parts = [];
    let totalLength = 0;

    for (const part of blobParts) {
      let bytes;
      if (typeof part === "string") {
        bytes = encodeUTF8(part);
      } else if (part instanceof ArrayBuffer) {
        bytes = new Uint8Array(part);
      } else if (ArrayBuffer.isView(part)) {
        bytes = new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
      } else if (part instanceof Blob) {
        bytes = part.#bytes;
      } else {
        bytes = encodeUTF8(String(part));
      }
      parts.push(bytes);
      totalLength += bytes.byteLength;
    }

    const merged = new Uint8Array(totalLength);
    let offset = 0;
    for (const part of parts) {
      merged.set(part, offset);
      offset += part.byteLength;
    }
    this.#bytes = merged;
  }

  get size() {
    return this.#bytes.byteLength;
  }

  get type() {
    return this.#type;
  }

  slice(start, end, contentType) {
    const size = this.size;
    let relStart = start === undefined ? 0 : clampIndex(start, size);
    let relEnd = end === undefined ? size : clampIndex(end, size);
    const span = Math.max(relEnd - relStart, 0);

    const sliced = new Blob();
    sliced.#bytes = this.#bytes.slice(relStart, relStart + span);
    sliced.#type = normalizeType(contentType ?? "");
    return sliced;
  }

  text() {
    return Promise.resolve(decodeUTF8(this.#bytes));
  }

  arrayBuffer() {
    return Promise.resolve(this.#bytes.buffer.slice(this.#bytes.byteOffset, this.#bytes.byteOffset + this.#bytes.byteLength));
  }

  toString() {
    return "[object Blob]";
  }

  get [Symbol.toStringTag]() {
    return "Blob";
  }
}

function normalizeType(type) {
  // Spec: type must be lowercase ASCII without 0x20-7E exclusions
  if (/[^\x20-\x7E]/.test(type)) {
    return "";
  }
  return type.toLowerCase();
}

function clampIndex(index, size) {
  if (index < 0) {
    return Math.max(size + index, 0);
  }
  return Math.min(index, size);
}

function encodeUTF8(str) {
  // Manual UTF-8 encoding for QuickJS (no TextEncoder)
  const utf8 = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);

    // Handle surrogate pairs
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      const next = str.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = (code - 0xd800) * 0x400 + (next - 0xdc00) + 0x10000;
        i++;
      }
    }

    if (code <= 0x7f) {
      utf8.push(code);
    } else if (code <= 0x7ff) {
      utf8.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code <= 0xffff) {
      utf8.push(
        0xe0 | (code >> 12),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f)
      );
    } else {
      utf8.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f)
      );
    }
  }
  return new Uint8Array(utf8);
}

function decodeUTF8(bytes) {
  // Manual UTF-8 decoding for QuickJS (no TextDecoder)
  let str = "";
  let i = 0;
  while (i < bytes.length) {
    let code;
    const b = bytes[i];
    if (b <= 0x7f) {
      code = b;
      i++;
    } else if ((b & 0xe0) === 0xc0) {
      code = ((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
      i += 2;
    } else if ((b & 0xf0) === 0xe0) {
      code =
        ((b & 0x0f) << 12) |
        ((bytes[i + 1] & 0x3f) << 6) |
        (bytes[i + 2] & 0x3f);
      i += 3;
    } else {
      code =
        ((b & 0x07) << 18) |
        ((bytes[i + 1] & 0x3f) << 12) |
        ((bytes[i + 2] & 0x3f) << 6) |
        (bytes[i + 3] & 0x3f);
      i += 4;
    }

    if (code <= 0xffff) {
      str += String.fromCharCode(code);
    } else {
      // Encode as surrogate pair
      code -= 0x10000;
      str += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    }
  }
  return str;
}

globalThis.Blob = Blob;
