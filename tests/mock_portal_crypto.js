// ============================================================================
//  tests/mock_portal_crypto.js -- TEST-ONLY crypto stub
// ----------------------------------------------------------------------------
//  The real portal ships its own private cipher inside crypto.js. This project
//  deliberately does NOT bundle that file (copyright); it downloads it from the
//  user's own portal at runtime instead.
//
//  This stub exists purely so the automated tests can run fully offline. It
//  exposes the same interface shape the portal script does (CryptoJS with
//  enc/mode/pad/VDX) so the encode engine's plumbing can be verified:
//    - script loads and CryptoJS becomes available
//    - cipher lookup, key parsing, mode/padding arguments are passed through
//    - ciphertext.toString() yields a lowercase hex string
//
//  It is NOT the real algorithm; its ciphertext differs from a real portal.
//  Genuine correctness is guaranteed at runtime by loading the portal's own
//  crypto.js, which has been verified to produce byte-identical output.
//
//  NOTE: ASCII-only on purpose -- the JScript engine reads .js files using the
//        system ANSI code page and misparses non-ASCII comments.
// ============================================================================

var HEXDIGITS = '0123456789abcdef';

function toHex(s) {
    var out = '';
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        out += HEXDIGITS.charAt((c >> 4) & 0xf);
        out += HEXDIGITS.charAt(c & 0xf);
    }
    return out;
}

var CryptoJS = {
    enc: {
        Utf8: {
            parse: function (s) { return { __utf8: String(s) }; }
        }
    },
    mode: { ECB: 'ECB' },
    pad: { ZeroPadding: 'ZeroPadding', Pkcs7: 'Pkcs7' },

    VDX: {
        encrypt: function (plain, keyObj, cfg) {
            var key = (keyObj && keyObj.__utf8) || '';
            var inHex = toHex(String(plain));
            var keyHex = toHex(key);
            var out = '';
            for (var i = 0; i < inHex.length; i++) {
                var a = HEXDIGITS.indexOf(inHex.charAt(i));
                var b = HEXDIGITS.indexOf(keyHex.charAt(i % keyHex.length));
                var v = (a ^ b) & 0xf;
                out += HEXDIGITS.charAt(v);
            }
            while (out.length % 8 !== 0) { out += '0'; }
            return {
                ciphertext: { toString: function () { return out; } }
            };
        }
    }
};

// Expose globally, the same way the real UMD portal script does.
this.CryptoJS = CryptoJS;
