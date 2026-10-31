/// IO builtin limits — the A-group semantics the contract pins for the IO nodes. These numbers are
/// language semantics, not accidents: interpreter and LLVM emitter must agree, so they live here
/// once. `readFile` reads whole files on both sides; only `readLine`'s `fgets` cap is bounded (`A1`).
package enum IOLimits {

    /// `readLine` — the `fgets` buffer size, in bytes. `fgets` yields at most `size - 1` characters
    /// plus a terminator, so the observable cap on a returned line is `lineBufferSize - 1`.
    package static let lineBufferSize = 256

    /// The largest line `readLine` can return, in bytes.
    package static let maxLineBytes = lineBufferSize - 1

    /// Truncate a line to the `fgets`-equivalent cap, **by byte**. When the cut lands inside a
    /// multi-byte character the LLVM side emits the raw bytes (an invalid UTF-8 sequence); a Swift
    /// `String` cannot hold those, so this side represents the same prefix with lenient decoding.
    package static func truncateToLineLimit(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.count > maxLineBytes else { return text }
        return String(decoding: bytes.prefix(maxLineBytes), as: UTF8.self)
    }
}
