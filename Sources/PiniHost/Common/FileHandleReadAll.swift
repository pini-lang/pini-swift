#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation

extension FileHandle {
    /// 读完到 EOF。不用 `readDataToEndOfFile()`：它在 Linux 上把 `readToEnd()` 的抛错交给
    /// `try!`，管道读被信号打断时抛的是 EINTR —— 进程直接 fatalError，连崩溃栈都打不出来。
    /// 这里走 POSIX `read`：EINTR 重试，读到 0 即 EOF，其余错误按 EOF 收尾。
    public func readAllData() -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                bkPOSIXRead(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            break
        }
        return data
    }
}

/// 扩展里直接写 `read` 会被解析成 `FileHandle.read`，故按模块限定后单独放一层。
private func bkPOSIXRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.read(fd, buffer, count)
    #elseif canImport(Darwin)
    return Darwin.read(fd, buffer, count)
    #else
    return -1
    #endif
}
