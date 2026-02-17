// W3C Blob, File, and FileReader polyfill for QuickJS
// Spec: https://www.w3.org/TR/FileAPI/

const _bytes = Symbol('bytes');

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

  [_bytes]() {
    return this.#bytes;
  }

  toString() {
    return "[object Blob]";
  }

  get [Symbol.toStringTag]() {
    return "Blob";
  }
}

function normalizeType(type) {
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
  const utf8 = [];
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
      code -= 0x10000;
      str += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    }
  }
  return str;
}

class File extends Blob {
  #name;
  #lastModified;

  constructor(fileBits, fileName, options) {
    if (arguments.length < 2) {
      throw new TypeError(
        "Failed to construct 'File': 2 arguments required, but only " +
          arguments.length +
          " present."
      );
    }

    super(fileBits, options);
    this.#name = String(fileName);
    this.#lastModified =
      options?.lastModified !== undefined
        ? Number(options.lastModified)
        : Date.now();
  }

  get name() {
    return this.#name;
  }

  get lastModified() {
    return this.#lastModified;
  }

  toString() {
    return "[object File]";
  }

  get [Symbol.toStringTag]() {
    return "File";
  }
}

class ProgressEvent {
  constructor(type, init) {
    this.type = type;
    this.target = null;
    this.lengthComputable = init?.lengthComputable ?? false;
    this.loaded = init?.loaded ?? 0;
    this.total = init?.total ?? 0;
  }
}

const EVENT_TYPES = ['loadstart', 'progress', 'load', 'abort', 'error', 'loadend'];

class FileReader {
  static EMPTY = 0;
  static LOADING = 1;
  static DONE = 2;

  #readyState = FileReader.EMPTY;
  #result = null;
  #error = null;
  #listeners = {};
  #aborted = false;

  constructor() {
    for (const type of EVENT_TYPES) {
      this['on' + type] = null;
    }
  }

  get readyState() { return this.#readyState; }
  get result() { return this.#result; }
  get error() { return this.#error; }

  get EMPTY() { return FileReader.EMPTY; }
  get LOADING() { return FileReader.LOADING; }
  get DONE() { return FileReader.DONE; }

  addEventListener(type, listener) {
    if (!this.#listeners[type]) {
      this.#listeners[type] = [];
    }
    this.#listeners[type].push(listener);
  }

  removeEventListener(type, listener) {
    const list = this.#listeners[type];
    if (!list) return;
    const idx = list.indexOf(listener);
    if (idx !== -1) list.splice(idx, 1);
  }

  #dispatch(type) {
    const event = new ProgressEvent(type);
    event.target = this;
    const handler = this['on' + type];
    if (typeof handler === 'function') {
      handler.call(this, event);
    }
    const list = this.#listeners[type];
    if (list) {
      for (const fn of list) {
        fn.call(this, event);
      }
    }
  }

  #read(blob, resultProducer) {
    if (!(blob instanceof Blob)) {
      throw new TypeError(
        "Failed to execute on 'FileReader': parameter 1 is not of type 'Blob'."
      );
    }
    if (this.#readyState === FileReader.LOADING) {
      throw new DOMException(
        "Failed to execute on 'FileReader': The object is already busy reading Blobs.",
        "InvalidStateError"
      );
    }

    this.#readyState = FileReader.LOADING;
    this.#result = null;
    this.#error = null;
    this.#aborted = false;

    Promise.resolve().then(() => {
      if (this.#aborted) return;
      this.#dispatch('loadstart');

      try {
        this.#result = resultProducer();
        this.#readyState = FileReader.DONE;
        if (!this.#aborted) {
          this.#dispatch('progress');
          this.#dispatch('load');
        }
      } catch (e) {
        this.#readyState = FileReader.DONE;
        this.#error = e;
        if (!this.#aborted) {
          this.#dispatch('error');
        }
      }

      if (!this.#aborted) {
        this.#dispatch('loadend');
      }
    });
  }

  readAsText(blob) {
    this.#read(blob, () => decodeUTF8(blob[_bytes]()));
  }

  abort() {
    if (this.#readyState === FileReader.EMPTY || this.#readyState === FileReader.DONE) {
      this.#result = null;
      return;
    }
    this.#aborted = true;
    this.#readyState = FileReader.DONE;
    this.#result = null;
    Promise.resolve().then(() => {
      this.#dispatch('abort');
      this.#dispatch('loadend');
    });
  }

  toString() {
    return "[object FileReader]";
  }

  get [Symbol.toStringTag]() {
    return "FileReader";
  }
}

globalThis.Blob = Blob;
globalThis.File = File;
globalThis.FileReader = FileReader;
