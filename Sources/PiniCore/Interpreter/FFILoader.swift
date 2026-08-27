import Foundation

/// Phase 2b（ADR-017）：库名 → 路径解析 + 句柄缓存 + 符号查找。
///
/// 库名（`[名称|foreign]` 的 `名称`，`fd.name` 升级为真实库绑定键）解析顺序：
/// 1. `libc` 保留名 → 直连系统 C 库（进程已加载映像，`SystemDL.openDefault`），不经路径搜索。
/// 2. 含路径分隔符（`/`）→ 直当路径加载。
/// 3. 否则按 `search_paths` 搜索 `lib<名称>.{dylib,so}`（子模块→根→系统默认）。
/// 句柄按库名缓存，避免重复 `dlopen`。
final class FFILoader {
 private var handles: [String: UnsafeMutableRawPointer] = [:]
 private let lock = NSLock()

 /// 解析 foreign 函数符号为裸地址（库句柄按名缓存）。
 /// - library：块名（库绑定键）。
 /// - searchPaths：合并后的 `FFIConfig.searchPaths`（`FFIConfig.default` 兜底系统路径）。
 func resolve(library: String, symbol: String, searchPaths: [String], location: SourceLocation) throws -> UnsafeMutableRawPointer {
 let handle = try openLibrary(library, searchPaths: searchPaths, location: location)
 guard let sym = SystemDL.symbol(handle, symbol) else {
 throw RuntimeError.symbolNotFound(library: library, symbol: symbol, location: location)
 }
 return sym
 }

 private func openLibrary(_ library: String, searchPaths: [String], location: SourceLocation) throws -> UnsafeMutableRawPointer {
 lock.lock(); defer { lock.unlock() }
 if let cached = handles[library] { return cached }

 let handle: UnsafeMutableRawPointer?
 let searched: [String]
 if library == "libc" {
 handle = SystemDL.openDefault()
 searched = ["（libc 保留名：进程已加载映像）"]
 } else if library.contains("/") {
 handle = SystemDL.open(library)
 searched = [library]
 } else {
 handle = openBySearch(name: library, searchPaths: searchPaths)
 searched = searchPaths
 }

 guard let h = handle else {
 throw RuntimeError.libraryNotFound(library: library, searched: searched, location: location)
 }
 handles[library] = h
 return h
 }

 /// 按 `search_paths` 搜索 `lib<名称>.{dylib,so}`；找到即 `dlopen` 返回句柄。
 private func openBySearch(name: String, searchPaths: [String]) -> UnsafeMutableRawPointer? {
 let exts = ["dylib", "so"]
 let fm = FileManager.default
 for dir in searchPaths {
 for ext in exts {
 let candidate = (dir as NSString).appendingPathComponent("lib\(name).\(ext)")
 if fm.fileExists(atPath: candidate), let h = SystemDL.open(candidate) { return h }
 }
 }
 return nil
 }
}
