import Foundation
import PiniSyntax

/// 库句柄缓存 + 符号解析。解析面只有两条：`[ffi].libs` 预加载的句柄，与进程已加载映像。
/// 块名不再是加载键 —— 生成模块只能按头文件命名，按块名找库会去找一个不存在的库。
final class FFILoader {
    private struct Handle {
        /// 报错与「已查」清单里显示的名字，与 `[ffi].libs` 的写法一致。
        let label: String
        let handle: UnsafeMutableRawPointer
    }

    /// 按声明次序保存：先声明的库优先，解析顺序对用户是可预期的。
    private var preloaded: [Handle] = []
    private var preloadedLibraries: Set<String> = []
    /// 进程映像句柄：`libc` 的符号就在主可执行体的搜索域里，不必显式加载。
    private var processImage: UnsafeMutableRawPointer?
    private let lock = NSLock()

    /// 预加载 `[ffi].libs` 并打开进程映像；重复调用只补新库，可以逐次 `prepare` 共用一份。
    /// 声明了要用的库却加载不到，就地报错 —— 符号解析失败只是它的下游症状。
    func preload(libraries: [String], searchPaths: [String], location: SourceLocation) throws {
        lock.lock()
        defer { lock.unlock() }
        if processImage == nil { processImage = SystemDL.openDefault() }
        preloadRuntimeIfPresent()
        for library in libraries where !preloadedLibraries.contains(library) {
            let opened = open(library, searchPaths: searchPaths)
            guard let handle = opened.handle else {
                throw RuntimeError.libraryNotFound(
                    library: library, searched: opened.searched, location: location)
            }
            preloadedLibraries.insert(library)
            preloaded.append(Handle(label: library, handle: handle))
        }
    }


    /// 运行时段库：`pini_*` 全在这份动态库里，而 CLI 自身不链接它 —— 只查进程映像解析不到。
    /// 找不到不报错：不用运行时段符号的程序照常跑，用户自己的库仍由 `[ffi].libs` 声明。
    private func preloadRuntimeIfPresent() {
        if preloadedLibraries.contains(FFILoader.runtimeLabel) { return }
        guard let path = runtimeLibraryPath(), let handle = SystemDL.open(path) else { return }
        preloadedLibraries.insert(FFILoader.runtimeLabel)
        preloaded.append(Handle(label: FFILoader.runtimeLabel, handle: handle))
    }

    /// 运行时段库标签：报错清单里显示它，与 `[ffi].libs` 的写法区分开。
    static let runtimeLabel = "PiniRuntime"

    /// 运行时段库定位：`PINI_RUNTIME_LIB` 优先，否则取可执行文件同目录的 `libPiniRuntime.{dylib,so}`。
    /// 与 `run-llvm` / `compile` 两条腿同一口径，三处因此不会指到不同的库。
    private func runtimeLibraryPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["PINI_RUNTIME_LIB"],
            !override.isEmpty, FileManager.default.fileExists(atPath: override)
        {
            return override
        }
        // 取可执行文件的绝对路径：`argv[0]` 是调用方的写法，测试会改工作目录，相对参拼出来落空。
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let absolute =
            raw.hasPrefix("/") ? raw
            : FileManager.default.currentDirectoryPath + "/" + raw
        let dir = (absolute as NSString).deletingLastPathComponent
        for ext in ["dylib", "so"] {
            let candidate = (dir as NSString).appendingPathComponent("libPiniRuntime.\(ext)")
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// 解析符号：先按声明次序查预加载的库，再查进程映像。
    /// 进程映像垫底，系统库因此不需要写进 `[ffi].libs`。
    func resolve(symbol: String, location: SourceLocation) throws -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        if processImage == nil { processImage = SystemDL.openDefault() }
        for entry in preloaded {
            if let address = SystemDL.symbol(entry.handle, symbol) { return address }
        }
        if let address = SystemDL.symbol(processImage, symbol) { return address }
        throw RuntimeError.symbolNotFound(
            symbol: symbol, searched: preloaded.map(\.label) + ["进程映像"], location: location)
    }

    /// 开一个库：含 `/` 的按路径，否则先按 `search_paths` 找 `lib<名>.{dylib,so}`，
    /// 再退回系统搜索路径（`libm` 这类不落在项目目录里的库由 dyld / ld.so 找）。
    private func open(
        _ library: String, searchPaths: [String]
    ) -> (handle: UnsafeMutableRawPointer?, searched: [String]) {
        if library.contains("/") {
            return (SystemDL.open(library), [library])
        }
        if let handle = openBySearch(name: library, searchPaths: searchPaths) {
            return (handle, searchPaths)
        }
        for ext in ["dylib", "so"] {
            if let handle = SystemDL.open("lib\(library).\(ext)") { return (handle, []) }
        }
        return (nil, searchPaths + ["系统默认路径"])
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
