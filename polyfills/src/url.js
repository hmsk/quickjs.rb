// WHATWG URL and URLSearchParams polyfill for QuickJS
// Spec: https://url.spec.whatwg.org/

const SPECIAL_SCHEMES = {
  ftp: 21,
  file: null,
  http: 80,
  https: 443,
  ws: 80,
  wss: 443,
};

function isSpecial(scheme) {
  return Object.prototype.hasOwnProperty.call(SPECIAL_SCHEMES, scheme);
}

function defaultPort(scheme) {
  return SPECIAL_SCHEMES[scheme] ?? null;
}

// Percent-encoding helpers
const C0_PERCENT_ENCODE = /[\x00-\x1f\x7f-\uffff]/;
const FRAGMENT_PERCENT_ENCODE = /[\x00-\x1f \x22\x3c\x3e\x60\x7f-\uffff]/;
const QUERY_PERCENT_ENCODE = /[\x00-\x1f \x22\x23\x3c\x3e\x7f-\uffff]/;
const SPECIAL_QUERY_PERCENT_ENCODE = /[\x00-\x1f \x22\x23\x27\x3c\x3e\x7f-\uffff]/;
const PATH_PERCENT_ENCODE = /[\x00-\x1f \x22\x23\x3c\x3e\x3f\x60\x7b-\x7d\x7f-\uffff]/;
const USERINFO_PERCENT_ENCODE = /[\x00-\x1f \x22\x23\x2f\x3a\x3b\x3d\x40\x5b-\x5e\x60\x7b-\x7d\x7f-\uffff]/;

function utf8PercentEncode(str, encodeSet) {
  let result = "";
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    const code = str.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      const next = str.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        const cp = (code - 0xd800) * 0x400 + (next - 0xdc00) + 0x10000;
        const bytes = encodeCodePoint(cp);
        for (const b of bytes) result += "%" + b.toString(16).toUpperCase().padStart(2, "0");
        i++;
        continue;
      }
    }
    if (encodeSet.test(c)) {
      const bytes = encodeCodePoint(code);
      for (const b of bytes) result += "%" + b.toString(16).toUpperCase().padStart(2, "0");
    } else {
      result += c;
    }
  }
  return result;
}

function encodeCodePoint(cp) {
  if (cp <= 0x7f) return [cp];
  if (cp <= 0x7ff) return [0xc0 | (cp >> 6), 0x80 | (cp & 0x3f)];
  if (cp <= 0xffff) return [0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)];
  return [0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)];
}

function percentDecode(str) {
  return str.replace(/%([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
}

function isAsciiDigit(c) { return c >= "0" && c <= "9"; }
function isAsciiHexDigit(c) { return (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F"); }
function isAsciiAlpha(c) { return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z"); }

function isWindowsDriveLetter(s, normalized) {
  if (s.length < 2) return false;
  if (!isAsciiAlpha(s[0])) return false;
  const second = s[1];
  if (normalized) return second === ":";
  return second === ":" || second === "|";
}

function startsWithWindowsDriveLetter(s) {
  if (s.length < 2) return false;
  if (!isAsciiAlpha(s[0])) return false;
  if (s[1] !== ":" && s[1] !== "|") return false;
  if (s.length === 2) return true;
  return s[2] === "/" || s[2] === "\\" || s[2] === "?" || s[2] === "#";
}

function shortenPath(path, scheme) {
  if (scheme === "file" && path.length === 1 && isWindowsDriveLetter(path[0], true)) return;
  if (path.length > 0) path.pop();
}

// URL record
function createURL() {
  return {
    scheme: "",
    username: "",
    password: "",
    host: null,
    port: null,
    path: [],
    query: null,
    fragment: null,
    cannotBeABaseURL: false,
  };
}

function serializeURL(url, excludeFragment) {
  let output = url.scheme + ":";
  if (url.host !== null) {
    output += "//";
    if (url.username !== "" || url.password !== "") {
      output += url.username;
      if (url.password !== "") output += ":" + url.password;
      output += "@";
    }
    output += serializeHost(url.host);
    if (url.port !== null) output += ":" + url.port;
  } else if (url.scheme === "file") {
    output += "//";
  }
  if (url.cannotBeABaseURL) {
    output += url.path[0] ?? "";
  } else {
    for (const segment of url.path) {
      output += "/" + segment;
    }
  }
  if (url.query !== null) output += "?" + url.query;
  if (!excludeFragment && url.fragment !== null) output += "#" + url.fragment;
  return output;
}

function serializeHost(host) {
  if (typeof host === "number") return serializeIPv4(host);
  if (Array.isArray(host)) return "[" + serializeIPv6(host) + "]";
  return host;
}

function serializeIPv4(addr) {
  let n = addr;
  const parts = [];
  for (let i = 0; i < 4; i++) {
    parts.unshift(n % 256);
    n = Math.floor(n / 256);
  }
  return parts.join(".");
}

function serializeIPv6(addr) {
  let output = "";
  const compress = longestRunOfZeroes(addr);
  let ignore = false;
  for (let i = 0; i < 8; i++) {
    if (ignore) {
      if (addr[i] !== 0) ignore = false;
      else continue;
    }
    if (i === compress) {
      output += i === 0 ? "::" : ":";
      ignore = true;
      continue;
    }
    output += addr[i].toString(16);
    if (i !== 7) output += ":";
  }
  return output;
}

function longestRunOfZeroes(addr) {
  let longestStart = -1, longestLen = 1;
  let start = -1, len = 0;
  for (let i = 0; i < 8; i++) {
    if (addr[i] === 0) {
      if (start === -1) { start = i; len = 0; }
      len++;
      if (len > longestLen) { longestLen = len; longestStart = start; }
    } else {
      start = -1;
    }
  }
  return longestStart;
}

function serializeOrigin(url) {
  if (isSpecial(url.scheme) && url.scheme !== "file") {
    return url.scheme + "://" + serializeHost(url.host) + (url.port !== null ? ":" + url.port : "");
  }
  return "null";
}

// Parsing helpers
function parseIPv4(input) {
  const parts = input.split(".");
  if (parts[parts.length - 1] === "") parts.pop();
  if (parts.length > 4) return null;
  const numbers = [];
  for (const p of parts) {
    if (p === "") return null;
    let n;
    if (/^0[xX]/.test(p)) {
      n = parseInt(p, 16);
    } else if (p.startsWith("0") && p.length > 1) {
      n = parseInt(p, 8);
    } else {
      n = parseInt(p, 10);
    }
    if (isNaN(n) || n < 0) return null;
    numbers.push(n);
  }
  if (numbers.some((n, i) => i < numbers.length - 1 && n > 255)) return null;
  const last = numbers[numbers.length - 1];
  if (last >= 256 ** (5 - numbers.length)) return null;
  let ipv4 = last;
  for (let i = 0; i < numbers.length - 1; i++) {
    if (numbers[i] > 255) return null;
    ipv4 += numbers[i] * 256 ** (3 - i);
  }
  return ipv4;
}

function parseIPv6(input) {
  const addr = [0, 0, 0, 0, 0, 0, 0, 0];
  let pieceIndex = 0;
  let compress = null;
  let pointer = 0;

  if (input[pointer] === ":" && input[pointer + 1] === ":") {
    pointer += 2;
    pieceIndex++;
    compress = pieceIndex;
  }

  while (pointer < input.length) {
    if (pieceIndex === 8) return null;
    if (input[pointer] === ":") {
      if (compress !== null) return null;
      pointer++;
      pieceIndex++;
      compress = pieceIndex;
      continue;
    }
    let value = 0;
    let length = 0;
    while (length < 4 && pointer < input.length && isAsciiHexDigit(input[pointer])) {
      value = value * 16 + parseInt(input[pointer], 16);
      pointer++;
      length++;
    }
    if (pointer < input.length && input[pointer] === ".") {
      if (length === 0) return null;
      pointer -= length;
      if (pieceIndex > 6) return null;
      let numbersSeen = 0;
      while (pointer < input.length) {
        let ipv4Piece = null;
        if (numbersSeen > 0) {
          if (input[pointer] === "." && numbersSeen < 4) pointer++;
          else return null;
        }
        if (!isAsciiDigit(input[pointer])) return null;
        while (pointer < input.length && isAsciiDigit(input[pointer])) {
          const n = parseInt(input[pointer], 10);
          ipv4Piece = ipv4Piece === null ? n : ipv4Piece * 10 + n;
          if (ipv4Piece > 255) return null;
          pointer++;
        }
        addr[pieceIndex] = addr[pieceIndex] * 256 + ipv4Piece;
        numbersSeen++;
        if (numbersSeen === 2 || numbersSeen === 4) pieceIndex++;
      }
      if (numbersSeen !== 4) return null;
      break;
    } else if (pointer < input.length && input[pointer] === ":") {
      pointer++;
      if (pointer >= input.length) return null;
    } else if (pointer < input.length) {
      return null;
    }
    addr[pieceIndex] = value;
    pieceIndex++;
  }

  if (compress !== null) {
    let swaps = pieceIndex - compress;
    pieceIndex = 7;
    while (pieceIndex !== 0 && swaps > 0) {
      [addr[pieceIndex], addr[compress + swaps - 1]] = [addr[compress + swaps - 1], addr[pieceIndex]];
      pieceIndex--;
      swaps--;
    }
  } else if (compress === null && pieceIndex !== 8) {
    return null;
  }
  return addr;
}

function parseOpaqueHost(input) {
  for (const c of input) {
    if (" #%/:?@[\\]".includes(c)) return null;
    if (c.charCodeAt(0) > 0x7e) return null;
  }
  return utf8PercentEncode(input, C0_PERCENT_ENCODE);
}

function parseHost(input, isNotSpecial) {
  if (input.startsWith("[")) {
    if (!input.endsWith("]")) return null;
    return parseIPv6(input.slice(1, -1));
  }
  if (isNotSpecial) return parseOpaqueHost(input);

  const domain = percentDecode(input).toLowerCase();

  if (!domain) return null;

  // Simple IPv4 check
  const ipv4 = parseIPv4(domain);
  if (ipv4 !== null) return ipv4;

  // Validate domain - basic checks
  if (domain.includes("..")) return null;

  return domain;
}

// Basic URL parser
function basicURLParse(input, base, url, stateOverride) {
  if (!url) url = createURL();

  input = input.trim().replace(/[\t\n\r]/g, "");

  let state = stateOverride || "scheme start";
  let buffer = "";
  let atFlag = false;
  let bracketFlag = false;
  let passwordTokenSeen = false;
  let pointer = 0;

  while (pointer <= input.length) {
    const c = input[pointer];

    switch (state) {
      case "scheme start":
        if (c !== undefined && isAsciiAlpha(c)) {
          buffer += c.toLowerCase();
          state = "scheme";
        } else if (!stateOverride) {
          state = "no scheme";
          continue;
        } else {
          return null;
        }
        break;

      case "scheme":
        if (c !== undefined && (isAsciiAlpha(c) || isAsciiDigit(c) || "+-." .includes(c))) {
          buffer += c.toLowerCase();
        } else if (c === ":") {
          if (stateOverride) {
            const wasSpecial = isSpecial(url.scheme);
            const willBeSpecial = isSpecial(buffer);
            if (wasSpecial !== willBeSpecial) return url;
            if ((buffer === "http" || buffer === "https") && url.scheme === "file") return url;
            if (url.scheme === "file" && (url.host === "" || url.host === null)) return url;
          }
          url.scheme = buffer;
          if (stateOverride) {
            if (url.port === defaultPort(url.scheme)) url.port = null;
            return url;
          }
          buffer = "";
          if (url.scheme === "file") {
            state = "file";
          } else if (isSpecial(url.scheme) && base && base.scheme === url.scheme) {
            state = "special relative or authority";
          } else if (isSpecial(url.scheme)) {
            state = "special authority slashes";
          } else if (input[pointer + 1] === "/") {
            state = "path or authority";
            pointer++;
          } else {
            url.cannotBeABaseURL = true;
            url.path.push("");
            state = "cannot-be-a-base-URL path";
          }
        } else if (!stateOverride) {
          buffer = "";
          state = "no scheme";
          pointer = -1;
        } else {
          return null;
        }
        break;

      case "no scheme":
        if (!base || (base.cannotBeABaseURL && c !== "#")) {
          return null;
        }
        if (base.cannotBeABaseURL && c === "#") {
          url.scheme = base.scheme;
          url.path = base.path.slice();
          url.query = base.query;
          url.fragment = "";
          url.cannotBeABaseURL = true;
          state = "fragment";
          break;
        }
        if (base.scheme !== "file") {
          state = "relative";
        } else {
          state = "file";
        }
        continue;

      case "special relative or authority":
        if (c === "/" && input[pointer + 1] === "/") {
          state = "special authority ignore slashes";
          pointer++;
        } else {
          state = "relative";
          continue;
        }
        break;

      case "path or authority":
        if (c === "/") {
          state = "authority";
        } else {
          state = "path";
          continue;
        }
        break;

      case "relative":
        url.scheme = base.scheme;
        if (c === undefined) {
          url.username = base.username;
          url.password = base.password;
          url.host = base.host;
          url.port = base.port;
          url.path = base.path.slice();
          url.query = base.query;
        } else if (c === "/") {
          state = "relative slash";
        } else if (c === "?") {
          url.username = base.username;
          url.password = base.password;
          url.host = base.host;
          url.port = base.port;
          url.path = base.path.slice();
          url.query = "";
          state = "query";
        } else if (c === "#") {
          url.username = base.username;
          url.password = base.password;
          url.host = base.host;
          url.port = base.port;
          url.path = base.path.slice();
          url.query = base.query;
          url.fragment = "";
          state = "fragment";
        } else {
          if (isSpecial(url.scheme) && c === "\\") {
            state = "relative slash";
          } else {
            url.username = base.username;
            url.password = base.password;
            url.host = base.host;
            url.port = base.port;
            url.path = base.path.slice();
            if (url.path.length > 0) url.path.pop();
            state = "path";
            continue;
          }
        }
        break;

      case "relative slash":
        if (isSpecial(url.scheme) && (c === "/" || c === "\\")) {
          state = "special authority ignore slashes";
        } else if (c === "/") {
          state = "authority";
        } else {
          url.username = base.username;
          url.password = base.password;
          url.host = base.host;
          url.port = base.port;
          state = "path";
          continue;
        }
        break;

      case "special authority slashes":
        if (c === "/" && input[pointer + 1] === "/") {
          state = "special authority ignore slashes";
          pointer++;
        } else {
          state = "special authority ignore slashes";
          continue;
        }
        break;

      case "special authority ignore slashes":
        if (c !== "/" && c !== "\\") {
          state = "authority";
          continue;
        }
        break;

      case "authority":
        if (c === "@") {
          if (atFlag) buffer = "%40" + buffer;
          atFlag = true;
          for (let i = 0; i < buffer.length; i++) {
            const bc = buffer[i];
            if (bc === ":" && !passwordTokenSeen) {
              passwordTokenSeen = true;
              continue;
            }
            const encodedCodePoints = utf8PercentEncode(bc, USERINFO_PERCENT_ENCODE);
            if (passwordTokenSeen) url.password += encodedCodePoints;
            else url.username += encodedCodePoints;
          }
          buffer = "";
        } else if (c === undefined || c === "/" || c === "?" || c === "#" || (isSpecial(url.scheme) && c === "\\")) {
          if (atFlag && buffer === "") return null;
          pointer -= buffer.length + 1;
          buffer = "";
          state = "host";
        } else {
          buffer += c;
        }
        break;

      case "host":
      case "hostname":
        if (stateOverride && url.scheme === "file") {
          state = "file host";
          continue;
        } else if (c === ":" && !bracketFlag) {
          if (buffer === "") return null;
          const host = parseHost(buffer, !isSpecial(url.scheme));
          if (host === null) return null;
          url.host = host;
          buffer = "";
          state = "port";
          if (stateOverride === "hostname") return url;
        } else if (c === undefined || c === "/" || c === "?" || c === "#" || (isSpecial(url.scheme) && c === "\\")) {
          if (isSpecial(url.scheme) && buffer === "") return null;
          if (stateOverride && buffer === "" && (url.username !== "" || url.password !== "" || url.port !== null)) return url;
          const host = parseHost(buffer, !isSpecial(url.scheme));
          if (host === null) return null;
          url.host = host;
          buffer = "";
          state = "path start";
          if (stateOverride) return url;
          continue;
        } else {
          if (c === "[") bracketFlag = true;
          if (c === "]") bracketFlag = false;
          buffer += c;
        }
        break;

      case "port":
        if (isAsciiDigit(c)) {
          buffer += c;
        } else if (c === undefined || c === "/" || c === "?" || c === "#" || (isSpecial(url.scheme) && c === "\\") || stateOverride) {
          if (buffer !== "") {
            const port = parseInt(buffer, 10);
            if (port > 65535) return null;
            url.port = port === defaultPort(url.scheme) ? null : port;
            buffer = "";
          }
          if (stateOverride) return url;
          state = "path start";
          continue;
        } else {
          return null;
        }
        break;

      case "file":
        url.scheme = "file";
        url.host = "";
        if (c === "/" || c === "\\") {
          state = "file slash";
        } else if (base && base.scheme === "file") {
          url.host = base.host;
          url.path = base.path.slice();
          url.query = base.query;
          if (c === "?") {
            url.query = "";
            state = "query";
          } else if (c === "#") {
            url.fragment = "";
            state = "fragment";
          } else if (c !== undefined) {
            url.query = null;
            if (!startsWithWindowsDriveLetter(input.slice(pointer))) {
              shortenPath(url.path, url.scheme);
            } else {
              url.path = [];
            }
            state = "path";
            continue;
          }
        } else {
          state = "path";
          continue;
        }
        break;

      case "file slash":
        if (c === "/" || c === "\\") {
          state = "file host";
        } else {
          if (base && base.scheme === "file") {
            url.host = base.host;
            if (!startsWithWindowsDriveLetter(input.slice(pointer)) && base.path.length > 0 && isWindowsDriveLetter(base.path[0], true)) {
              url.path.push(base.path[0]);
            }
          }
          state = "path";
          continue;
        }
        break;

      case "file host":
        if (c === undefined || c === "/" || c === "\\" || c === "?" || c === "#") {
          if (!stateOverride && isWindowsDriveLetter(buffer, false)) {
            state = "path";
          } else if (buffer === "") {
            url.host = "";
            if (stateOverride) return url;
            state = "path start";
          } else {
            const host = parseHost(buffer, false);
            if (host === null) return null;
            url.host = host === "localhost" ? "" : host;
            if (stateOverride) return url;
            buffer = "";
            state = "path start";
          }
          continue;
        } else {
          buffer += c;
        }
        break;

      case "path start":
        if (isSpecial(url.scheme)) {
          state = "path";
          if (c !== "/" && c !== "\\") continue;
        } else if (!stateOverride && c === "?") {
          url.query = "";
          state = "query";
        } else if (!stateOverride && c === "#") {
          url.fragment = "";
          state = "fragment";
        } else if (c !== undefined) {
          state = "path";
          if (c !== "/") continue;
        } else if (stateOverride && url.host === null) {
          url.path.push("");
        }
        break;

      case "path":
        if (c === undefined || c === "/" || (isSpecial(url.scheme) && c === "\\") || (!stateOverride && (c === "?" || c === "#"))) {
          const decoded = buffer.toLowerCase();
          if (decoded === "%2e" || decoded === ".") {
            buffer = ".";
          } else if (decoded === "%2e%2e" || decoded === ".%2e" || decoded === "%2e." || decoded === "..") {
            buffer = "..";
          }
          if (buffer === "..") {
            shortenPath(url.path, url.scheme);
            if (c !== "/" && !(isSpecial(url.scheme) && c === "\\")) {
              url.path.push("");
            }
          } else if (buffer === ".") {
            if (c !== "/" && !(isSpecial(url.scheme) && c === "\\")) {
              url.path.push("");
            }
          } else {
            if (url.scheme === "file" && url.path.length === 0 && isWindowsDriveLetter(buffer, false)) {
              buffer = buffer[0] + ":";
            }
            url.path.push(buffer);
          }
          buffer = "";
          if (c === "?") {
            url.query = "";
            state = "query";
          } else if (c === "#") {
            url.fragment = "";
            state = "fragment";
          }
        } else {
          buffer += utf8PercentEncode(c, PATH_PERCENT_ENCODE);
        }
        break;

      case "cannot-be-a-base-URL path":
        if (c === "?") {
          url.query = "";
          state = "query";
        } else if (c === "#") {
          url.fragment = "";
          state = "fragment";
        } else if (c !== undefined) {
          url.path[0] += utf8PercentEncode(c, C0_PERCENT_ENCODE);
        }
        break;

      case "query":
        if (c === undefined || (!stateOverride && c === "#")) {
          const encodeSet = isSpecial(url.scheme) ? SPECIAL_QUERY_PERCENT_ENCODE : QUERY_PERCENT_ENCODE;
          url.query += utf8PercentEncode(buffer, encodeSet);
          buffer = "";
          if (c === "#") {
            url.fragment = "";
            state = "fragment";
          }
        } else {
          buffer += c;
        }
        break;

      case "fragment":
        if (c !== undefined) {
          url.fragment += utf8PercentEncode(c, FRAGMENT_PERCENT_ENCODE);
        }
        break;
    }

    pointer++;
  }

  return url;
}

// URLSearchParams
class URLSearchParams {
  #list;
  #url;

  constructor(init = "") {
    this.#list = [];
    this.#url = null;

    if (typeof init === "string") {
      if (init.startsWith("?")) init = init.slice(1);
      this.#list = parseQueryString(init);
    } else if (Array.isArray(init)) {
      for (const pair of init) {
        if (!Array.isArray(pair) || pair.length !== 2) {
          throw new TypeError("Each pair must be an iterable [name, value] tuple");
        }
        this.#list.push([String(pair[0]), String(pair[1])]);
      }
    } else if (init !== null && typeof init === "object") {
      for (const key of Object.keys(init)) {
        this.#list.push([key, String(init[key])]);
      }
    }
  }

  _setURL(url) {
    this.#url = url;
  }

  _update() {
    if (this.#url) {
      const serialized = this.toString();
      this.#url._urlRecord.query = serialized === "" ? null : serialized;
    }
  }

  append(name, value) {
    this.#list.push([String(name), String(value)]);
    this._update();
  }

  delete(name, value) {
    name = String(name);
    if (value !== undefined) {
      value = String(value);
      this.#list = this.#list.filter(([n, v]) => !(n === name && v === value));
    } else {
      this.#list = this.#list.filter(([n]) => n !== name);
    }
    this._update();
  }

  get(name) {
    name = String(name);
    const entry = this.#list.find(([n]) => n === name);
    return entry ? entry[1] : null;
  }

  getAll(name) {
    name = String(name);
    return this.#list.filter(([n]) => n === name).map(([, v]) => v);
  }

  has(name, value) {
    name = String(name);
    if (value !== undefined) {
      value = String(value);
      return this.#list.some(([n, v]) => n === name && v === value);
    }
    return this.#list.some(([n]) => n === name);
  }

  set(name, value) {
    name = String(name);
    value = String(value);
    let found = false;
    this.#list = this.#list.filter(([n]) => {
      if (n === name) {
        if (!found) { found = true; return true; }
        return false;
      }
      return true;
    });
    if (!found) this.#list.push([name, value]);
    else {
      const idx = this.#list.findIndex(([n]) => n === name);
      this.#list[idx][1] = value;
    }
    this._update();
  }

  sort() {
    this.#list.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
    this._update();
  }

  keys() {
    return this.#list.map(([k]) => k)[Symbol.iterator]();
  }

  values() {
    return this.#list.map(([, v]) => v)[Symbol.iterator]();
  }

  entries() {
    return this.#list.slice()[Symbol.iterator]();
  }

  forEach(callback, thisArg) {
    for (const [name, value] of this.#list) {
      callback.call(thisArg, value, name, this);
    }
  }

  [Symbol.iterator]() {
    return this.entries();
  }

  get size() {
    return this.#list.length;
  }

  toString() {
    return this.#list.map(([k, v]) => encodeFormComponent(k) + "=" + encodeFormComponent(v)).join("&");
  }

  get [Symbol.toStringTag]() {
    return "URLSearchParams";
  }
}

function parseQueryString(query) {
  if (query === "") return [];
  return query.split("&").map(pair => {
    const eqIdx = pair.indexOf("=");
    let name, value;
    if (eqIdx === -1) {
      name = pair;
      value = "";
    } else {
      name = pair.slice(0, eqIdx);
      value = pair.slice(eqIdx + 1);
    }
    return [decodeFormComponent(name), decodeFormComponent(value)];
  });
}

function encodeFormComponent(str) {
  return str.replace(/[^*\-._A-Za-z0-9]/g, c => {
    if (c === " ") return "+";
    const bytes = encodeCodePoint(c.charCodeAt(0));
    return bytes.map(b => "%" + b.toString(16).toUpperCase().padStart(2, "0")).join("");
  });
}

function decodeFormComponent(str) {
  return decodeURIComponent(str.replace(/\+/g, " "));
}

// URL class
class URL {
  #urlRecord;
  #searchParams;

  constructor(url, base) {
    let parsedBase = null;
    if (base !== undefined) {
      parsedBase = basicURLParse(String(base));
      if (parsedBase === null) {
        throw new TypeError("Failed to construct 'URL': Invalid base URL");
      }
    }
    const parsed = basicURLParse(String(url), parsedBase);
    if (parsed === null) {
      throw new TypeError("Failed to construct 'URL': Invalid URL");
    }
    this.#urlRecord = parsed;
    this.#searchParams = new URLSearchParams(parsed.query ?? "");
    this.#searchParams._setURL(this);
  }

  get _urlRecord() { return this.#urlRecord; }

  get href() {
    return serializeURL(this.#urlRecord, false);
  }

  set href(value) {
    const parsed = basicURLParse(String(value));
    if (parsed === null) throw new TypeError("Invalid URL");
    this.#urlRecord = parsed;
    this.#searchParams = new URLSearchParams(parsed.query ?? "");
    this.#searchParams._setURL(this);
  }

  get origin() {
    return serializeOrigin(this.#urlRecord);
  }

  get protocol() {
    return this.#urlRecord.scheme + ":";
  }

  set protocol(value) {
    basicURLParse(String(value) + ":", null, this.#urlRecord, "scheme start");
  }

  get username() {
    return this.#urlRecord.username;
  }

  set username(value) {
    if (this.#urlRecord.host === null || this.#urlRecord.host === "" || this.#urlRecord.cannotBeABaseURL || this.#urlRecord.scheme === "file") return;
    this.#urlRecord.username = utf8PercentEncode(String(value), USERINFO_PERCENT_ENCODE);
  }

  get password() {
    return this.#urlRecord.password;
  }

  set password(value) {
    if (this.#urlRecord.host === null || this.#urlRecord.host === "" || this.#urlRecord.cannotBeABaseURL || this.#urlRecord.scheme === "file") return;
    this.#urlRecord.password = utf8PercentEncode(String(value), USERINFO_PERCENT_ENCODE);
  }

  get host() {
    const url = this.#urlRecord;
    if (url.host === null) return "";
    if (url.port === null) return serializeHost(url.host);
    return serializeHost(url.host) + ":" + url.port;
  }

  set host(value) {
    if (this.#urlRecord.cannotBeABaseURL) return;
    basicURLParse(String(value), null, this.#urlRecord, "host");
  }

  get hostname() {
    if (this.#urlRecord.host === null) return "";
    return serializeHost(this.#urlRecord.host);
  }

  set hostname(value) {
    if (this.#urlRecord.cannotBeABaseURL) return;
    basicURLParse(String(value), null, this.#urlRecord, "hostname");
  }

  get port() {
    if (this.#urlRecord.port === null) return "";
    return String(this.#urlRecord.port);
  }

  set port(value) {
    if (this.#urlRecord.host === null || this.#urlRecord.host === "" || this.#urlRecord.cannotBeABaseURL || this.#urlRecord.scheme === "file") return;
    value = String(value);
    if (value === "") {
      this.#urlRecord.port = null;
    } else {
      basicURLParse(value, null, this.#urlRecord, "port");
    }
  }

  get pathname() {
    const url = this.#urlRecord;
    if (url.cannotBeABaseURL) return url.path[0] ?? "";
    if (url.path.length === 0) return "";
    return "/" + url.path.join("/");
  }

  set pathname(value) {
    if (this.#urlRecord.cannotBeABaseURL) return;
    this.#urlRecord.path = [];
    basicURLParse(String(value), null, this.#urlRecord, "path start");
  }

  get search() {
    if (this.#urlRecord.query === null || this.#urlRecord.query === "") return "";
    return "?" + this.#urlRecord.query;
  }

  set search(value) {
    value = String(value);
    if (value === "") {
      this.#urlRecord.query = null;
      this.#searchParams = new URLSearchParams("");
      this.#searchParams._setURL(this);
      return;
    }
    if (value.startsWith("?")) value = value.slice(1);
    this.#urlRecord.query = "";
    basicURLParse(value, null, this.#urlRecord, "query");
    this.#searchParams = new URLSearchParams(this.#urlRecord.query ?? "");
    this.#searchParams._setURL(this);
  }

  get searchParams() {
    return this.#searchParams;
  }

  get hash() {
    if (this.#urlRecord.fragment === null || this.#urlRecord.fragment === "") return "";
    return "#" + this.#urlRecord.fragment;
  }

  set hash(value) {
    value = String(value);
    if (value === "") {
      this.#urlRecord.fragment = null;
      return;
    }
    if (value.startsWith("#")) value = value.slice(1);
    this.#urlRecord.fragment = "";
    basicURLParse(value, null, this.#urlRecord, "fragment");
  }

  toString() {
    return this.href;
  }

  toJSON() {
    return this.href;
  }

  get [Symbol.toStringTag]() {
    return "URL";
  }

  static canParse(url, base) {
    try {
      new URL(url, base);
      return true;
    } catch {
      return false;
    }
  }

  static parse(url, base) {
    try {
      return new URL(url, base);
    } catch {
      return null;
    }
  }
}

globalThis.URL = URL;
globalThis.URLSearchParams = URLSearchParams;
