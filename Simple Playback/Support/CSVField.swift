import Foundation

/// RFC 4180 field quoting helper, shared by every CSV-emitting service.
///
/// Wraps a value in `"…"` if it contains any of: comma `,`, double-quote `"`,
/// CR `\r`, or LF `\n`. Embedded `"` characters are doubled to `""` per
/// RFC 4180 §2.7. Strings that don't need quoting pass through verbatim.
///
/// Consolidated from two near-identical file-private copies during the
/// review pass — `Services/ShowLog.swift` carried one (without `\r`) and
/// `Services/PostShowCSVExporter.swift` carried another (with `\r`). One
/// canonical helper means a future operator-supplied detail string with
/// `\r\n` line endings (Windows-pasted notes, e.g.) gets consistent
/// quoting in both the live show log and the post-show export.
enum CSVField {
    static func quoted(_ value: String) -> String {
        // Swift's `String.contains("\r")` treats `\r\n` as a single grapheme
        // cluster, so a Windows-pasted note containing CRLF would slip
        // through the check undetected (the `\r` doesn't match because the
        // grapheme is the pair). Walk the unicode scalars — that's the
        // raw byte view we actually care about for CSV parser compatibility.
        let needsQuote = value.unicodeScalars.contains { scalar in
            scalar == ","
                || scalar == "\""
                || scalar == "\n"
                || scalar == "\r"
        }
        guard needsQuote else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
