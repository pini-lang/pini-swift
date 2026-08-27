import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Phase 2b（ADR-017）：跨平台动态链接封装（Darwin / Linux）。
///
/// 屏蔽 macOS `.dylib` 与 Linux `.so` 差异，提供 `dlopen`/`dlsym`/`dlclose` 薄封装。
/// 仅返回裸地址（`UnsafeMutableRawPointer`）；调用侧（`ForeignThunk`）负责按精确 C 签名
/// 转成 `@convention(c)` 函数指针——本层不涉 ABI 语义。
enum SystemDL {
 /// 打开动态库；`path` 为库文件路径。失败返回 `nil`（错误经 `error()` 获取）。
 static func open(_ path: String) -> UnsafeMutableRawPointer? {
 return path.withCString { dlopen($0, RTLD_NOW) }
 }

 /// 打开「默认」句柄：覆盖主可执行体 + 已加载依赖（含 libc）的搜索域。
 /// 用于 `libc` 保留库名——不经路径搜索，直接在进程已加载映像中查符号。
 static func openDefault() -> UnsafeMutableRawPointer? {
 return dlopen(nil, RTLD_NOW)
 }

 /// 在句柄中查找符号，返回裸函数/数据地址；未找到返回 `nil`。
 static func symbol(_ handle: UnsafeMutableRawPointer?, _ name: String) -> UnsafeMutableRawPointer? {
 guard let handle = handle else { return nil }
 return name.withCString { dlsym(handle, $0) }
 }

 static func close(_ handle: UnsafeMutableRawPointer?) {
 if let handle = handle { dlclose(handle) }
 }

 /// 最近一次 dl 错误（线程局部）；无错误返回 `nil`。
 static func error() -> String? {
 let err = dlerror()
 if let err = err { return String(cString: err) }
 return nil
 }
}
