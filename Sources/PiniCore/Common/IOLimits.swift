/// IO builtin limits — the A-group semantics the contract pins for the IO nodes
/// (`IR 契约` D3 unified the interpreter to the LLVM side).
///
/// These numbers are **language semantics**, not implementation accidents:
/// the interpreter and the LLVM emitter both have to agree on them, so they are
/// defined once here and consulted from both sides instead of being spelled out
/// twice and drifting apart.
///
/// ⚠️⭐ **`readFile` is not here any more** (2026-10-01, `auth-70`). It used to
/// be capped at `fileBufferSize` (64 KiB) with everything past the cap dropped
/// **silently** — no diagnostic, exit code 0. Two things were wrong with that:
///
/// 1. The contract's own semantics column for the node has always said *read
///    the entire contents*, and the cap was added by a later ruling. The two
///    were in conflict, and the semantics column is the one that survived.
/// 2. The magnitude was inherited from the emitter's fixed stack buffer, not
///    chosen — this file's own header said so. As long as it was here, the
///    language could not read its own sources back, and the failure surfaced
///    as a syntax error somewhere else entirely.
///
/// Both sides now read the whole file: the interpreter reads it out, and the
/// emitter calls the runtime shim (`bk_read_file`) instead of `fread`-ing into
/// a fixed buffer. ⛔ **Do not put a cap back here without a ruling.** The
/// sibling `listDir` ruling is explicit on the shape to use if one is ever
/// wanted: an arbitrary number is not introduced for free, and a short answer
/// fails loud rather than truncating.
///
/// `readLine`'s cap stays. It is `fgets`'s own buffer contract on both sides,
/// and it is documented language behaviour (`A1`) rather than an accident.
internal enum IOLimits {

    /// `readLine` — the `fgets` buffer size, in bytes.
    ///
    /// `fgets` yields at most `size - 1` characters plus a terminator, so the
    /// observable cap on a returned line is `lineBufferSize - 1`.
    static let lineBufferSize = 256

    /// The largest line `readLine` can return, in bytes.
    static let maxLineBytes = lineBufferSize - 1

    /// A1: truncate a line to the `fgets`-equivalent cap, **by byte**.
    ///
    /// When the cut lands inside a multi-byte character the LLVM side emits the
    /// raw bytes (an invalid UTF-8 sequence); a Swift `String` cannot hold
    /// those, so this side represents the same prefix with lenient decoding.
    /// That divergent representation is a consequence of the cap itself and
    /// travels with the cap's own case.
    static func truncateToLineLimit(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.count > maxLineBytes else { return text }
        return String(decoding: bytes.prefix(maxLineBytes), as: UTF8.self)
    }
}
