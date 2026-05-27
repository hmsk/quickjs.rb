// HTML Standard btoa/atob polyfill for QuickJS
// Spec: https://html.spec.whatwg.org/multipage/webappapis.html#atob

const BASE64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function invalidCharacterError(message) {
  const error = new Error(message);
  error.name = 'InvalidCharacterError';
  return error;
}

globalThis.btoa = function btoa(stringToEncode) {
  if (arguments.length === 0) {
    throw new TypeError("Failed to execute 'btoa': 1 argument required, but only 0 present.");
  }
  const str = String(stringToEncode);
  for (let i = 0; i < str.length; i++) {
    if (str.charCodeAt(i) > 0xFF) {
      throw invalidCharacterError(
        "Failed to execute 'btoa': The string to be encoded contains characters outside of the Latin1 range."
      );
    }
  }

  let result = '';
  const len = str.length;
  for (let i = 0; i < len; i += 3) {
    const b0 = str.charCodeAt(i);
    const b1 = i + 1 < len ? str.charCodeAt(i + 1) : 0;
    const b2 = i + 2 < len ? str.charCodeAt(i + 2) : 0;
    result += BASE64_CHARS[b0 >> 2];
    result += BASE64_CHARS[((b0 & 3) << 4) | (b1 >> 4)];
    result += i + 1 < len ? BASE64_CHARS[((b1 & 15) << 2) | (b2 >> 6)] : '=';
    result += i + 2 < len ? BASE64_CHARS[b2 & 63] : '=';
  }
  return result;
};

globalThis.atob = function atob(encodedData) {
  if (arguments.length === 0) {
    throw new TypeError("Failed to execute 'atob': 1 argument required, but only 0 present.");
  }
  const str = String(encodedData).replace(/[\t\n\f\r ]/g, '');
  if (str.length % 4 === 1 || /[^A-Za-z0-9+/=]/.test(str) || /=(?=[^=]|.+=)/.test(str)) {
    throw invalidCharacterError(
      "Failed to execute 'atob': The string to be decoded is not correctly encoded."
    );
  }

  let result = '';
  for (let i = 0; i < str.length; i += 4) {
    const a = BASE64_CHARS.indexOf(str[i]);
    const b = BASE64_CHARS.indexOf(str[i + 1]);
    const c = str[i + 2] === '=' ? 0 : BASE64_CHARS.indexOf(str[i + 2]);
    const d = str[i + 3] === '=' ? 0 : BASE64_CHARS.indexOf(str[i + 3]);

    result += String.fromCharCode((a << 2) | (b >> 4));
    if (str[i + 2] !== '=') result += String.fromCharCode(((b & 15) << 4) | (c >> 2));
    if (str[i + 3] !== '=') result += String.fromCharCode(((c & 3) << 6) | d);
  }
  return result;
};
