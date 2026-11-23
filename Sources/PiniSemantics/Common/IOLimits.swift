/// IO 内建的上限：解释器与 LLVM 后端必须给出同一组数字，故只在这里声明一次。
/// `readFile` 两端都整文件读入，不受限；只有 `readLine` 的 `fgets` 缓冲有上界。
package enum IOLimits {

    /// `readLine` 的 `fgets` 缓冲字节数。`fgets` 至多产出 `size - 1` 个字符加一个终止符，
    /// 故一行可见的上限是 `lineBufferSize - 1`。
    package static let lineBufferSize = 256

    /// `readLine` 能返回的最长一行，按字节计。
    package static let maxLineBytes = lineBufferSize - 1

    /// 按字节把一行截到 `fgets` 等价上限。切点落在多字节字符中间时，LLVM 侧照原样发出这些字节
    /// （一段非法 UTF-8），而 Swift 的 `String` 存不住，故这一侧用宽容解码表示同一段前缀。
    package static func truncateToLineLimit(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.count > maxLineBytes else { return text }
        return String(decoding: bytes.prefix(maxLineBytes), as: UTF8.self)
    }
}
