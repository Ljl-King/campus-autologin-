// ============================================================================
//  encode_engine.js -- Zero-dependency password encryption engine
// ----------------------------------------------------------------------------
//  Runtime : Windows Script Host (JScript), runs via the built-in cscript.exe.
//            Present on every Windows since Windows 7. Nothing to install.
//
//  Purpose : Load the portal's own crypto.js and encrypt the password with the
//            exact same algorithm the browser uses, then output the ciphertext
//            as a lowercase hex string.
//
//  Usage   :
//      cscript //nologo //E:JScript encode_engine.js <crypto.js> <job.json> <out.json>
//
//  Arguments:
//      crypto.js  portal encryption script (downloaded and cached locally)
//      job.json   input, UTF-16 encoded JSON:
//                 {"algorithm":"VDX","key":"<key>","input":"<plaintext>"}
//      out.json   output, UTF-16 encoded JSON:
//                 {"ok":true,"hex":"<ciphertext>"} or {"ok":false,"error":"..."}
//
//  Exit codes: 0 ok, 3 CryptoJS not exported, 4 algorithm not found, 9 error
//
//  NOTE: This file is intentionally ASCII-only. JScript reads .js files using
//        the system ANSI code page, so non-ASCII comments would be misparsed
//        and cause a bogus "Syntax error" on machines using other locales.
//        All user-facing Chinese text lives in the PowerShell layer instead.
// ============================================================================

var fso = new ActiveXObject("Scripting.FileSystemObject");
var args = WScript.Arguments;

// ---------------------------------------------------------------------------
// File helpers.
// Note: FileSystemObject can only read ANSI and UTF-16, so we use ADODB.Stream
//       to read the portal script (UTF-8) and to read/write the job/result JSON.
// ---------------------------------------------------------------------------

// Read a UTF-8 text file.
function readUtf8(path) {
    var st = new ActiveXObject("ADODB.Stream");
    st.Type = 2;              // 2 = text mode
    st.Charset = "utf-8";
    st.Open();
    st.LoadFromFile(path);
    var text = st.ReadText();
    st.Close();
    return text;
}

// Read a UTF-16 (Unicode) text file.
function readUnicode(path) {
    var st = new ActiveXObject("ADODB.Stream");
    st.Type = 2;
    st.Charset = "unicode";
    st.Open();
    st.LoadFromFile(path);
    var text = st.ReadText();
    st.Close();
    return text;
}

// Write a UTF-16 (Unicode) text file, overwriting any existing file.
function writeUnicode(path, text) {
    var st = new ActiveXObject("ADODB.Stream");
    st.Type = 2;
    st.Charset = "unicode";
    st.Open();
    st.WriteText(text);
    st.SaveToFile(path, 2);   // 2 = overwrite
    st.Close();
}

// Escape a string so it can be embedded in a JSON value.
function jsonEscape(s) {
    s = String(s);
    var out = "";
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i);
        var code = s.charCodeAt(i);
        if (c === '"') { out += '\\"'; }
        else if (c === '\\') { out += '\\\\'; }
        else if (code < 0x20) { out += '\\u' + ('000' + code.toString(16)).slice(-4); }
        else { out += c; }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Main routine.
// ---------------------------------------------------------------------------
function main() {
    var cryptoPath = args(0);
    var jobPath = args(1);
    var outPath = args(2);

    try {
        // 1) Evaluate the portal crypto.js in the global scope.
        //    It is a UMD bundle; with no module/define present it attaches the
        //    CryptoJS object to the global scope, exactly like in a browser.
        this.eval(readUtf8(cryptoPath));

        var CJ = this.CryptoJS;
        if (!CJ) {
            writeUnicode(outPath, '{"ok":false,"error":"portal crypto.js did not export CryptoJS"}');
            return 3;
        }

        // 2) Read the job description.
        var job = eval("(" + readUnicode(jobPath) + ")");
        var algoName = job.algorithm || "VDX";
        var cipher = CJ[algoName];
        if (!cipher) {
            writeUnicode(outPath, '{"ok":false,"error":"cipher not found in crypto.js: ' + jsonEscape(algoName) + '"}');
            return 4;
        }

        // 3) Encrypt exactly the way the portal front end does:
        //    key parsed as UTF-8, ECB mode, ZeroPadding, output as hex.
        var key = CJ.enc.Utf8.parse(job.key);
        var encrypted = cipher.encrypt(job.input, key, {
            iv: CJ.enc.Utf8.parse(""),
            mode: CJ.mode.ECB,
            padding: CJ.pad.ZeroPadding
        });

        writeUnicode(outPath, '{"ok":true,"hex":"' + encrypted.ciphertext.toString() + '"}');
        return 0;

    } catch (e) {
        var msg = (e && e.message) ? e.message : String(e);
        try { writeUnicode(outPath, '{"ok":false,"error":"' + jsonEscape(msg) + '"}'); } catch (e2) {}
        return 9;
    }
}

var rc = main();
WScript.Quit(rc);
