/// IO builtin limits — the A-group semantics the contract pins for the three
/// IO nodes (`IR 契约` D3 unified the interpreter to the LLVM side).
///
/// These numbers are **language semantics**, not implementation accidents:
/// the interpreter and the LLVM emitter both have to agree on them, so they
/// are defined once here and consulted from both sides instead of being
/// spelled out twice and drifting apart.
///
/// ⚠️ The magnitudes themselves are inherited from the emitter's fixed stack
/// buffers. Whether they *should* be the language's limits is a separate
/// question, registered on its own; this file only makes the agreed values
/// single-sourced.
internal enum IOLimits {

    /// `readLine` — the `fgets` buffer size, in bytes.
    ///
    /// `fgets` yields at most `size - 1` characters plus a terminator, so the
    /// observable cap on a returned line is `lineBufferSize - 1`.
    static let lineBufferSize = 256

    /// The largest line `readLine` can return, in bytes.
    static let maxLineBytes = lineBufferSize - 1

    /// `readFile` — the whole file is read into a buffer of this many bytes;
    /// anything beyond it is **silently truncated**.
    static let fileBufferSize = 65_536

    /// A2: truncate to the file cap, **by byte** — the same unit the LLVM
    /// side's `fread` count uses.
    ///
    /// When the cut lands inside a multi-byte character the LLVM side emits
    /// the raw bytes (an invalid UTF-8 sequence); a Swift `String` cannot
    /// hold those, so this side represents the same prefix with lenient
    /// decoding. The divergent representation for that boundary is a
    /// consequence of the cap itself and travels with the cap's own case.
    static func truncateToFileLimit(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.count > fileBufferSize else { return text }
        return String(decoding: bytes.prefix(fileBufferSize), as: UTF8.self)
    }

    /// A1: truncate a line to the `fgets`-equivalent cap, **by byte**.
    ///
    /// Same unit and same multi-byte-character caveat as the file cap.
    static func truncateToLineLimit(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.count > maxLineBytes else { return text }
        return String(decoding: bytes.prefix(maxLineBytes), as: UTF8.self)
    }
}
