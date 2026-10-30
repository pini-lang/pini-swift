#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// 跨平台线程本地存储：底层是 POSIX `pthread_key_t`，每线程一份独立副本，线程退出时由注册的
/// 销毁器释放值盒子，无泄漏。可替代仅 Apple 平台可用的 `Thread.current.threadDictionary`，
/// 使解释器在 Linux 编译通过；并发任务隔离即靠它给每个 `=>` worker 维护独立的环境状态。
final class ThreadLocal<T> {
    private var key: pthread_key_t

    init() {
        var k = pthread_key_t()
        // 销毁器：线程退出时释放当前线程持有的盒子（匹配下方 set 中的 passRetained）。
        // 用 AnyObject 类型擦除避免捕获泛型 T（否则无法形成 C 函数指针）。
        // Glibc 的形参可空、Darwin 不可空；语义相同，两处签名只能各写一遍。
        #if canImport(Glibc)
            let destructor: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
                guard let raw else { return }
                Unmanaged<AnyObject>.fromOpaque(raw).release()
            }
        #else
            let destructor: @convention(c) (UnsafeMutableRawPointer) -> Void = { raw in
                Unmanaged<AnyObject>.fromOpaque(raw).release()
            }
        #endif
        pthread_key_create(&k, destructor)
        self.key = k
    }

    /// 当前线程持有的值；未设置则为 `nil`。
    var value: T? {
        get {
            guard let raw = pthread_getspecific(key) else { return nil }
            let box = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as! Box<T>
            return box.value
        }
        set {
            // 释放旧盒子（覆盖写避免泄漏），再存入新盒子（passRetained 交由线程退出销毁器 release）。
            if let raw = pthread_getspecific(key) {
                Unmanaged<AnyObject>.fromOpaque(raw).release()
            }
            if let newValue = newValue {
                let box: AnyObject = Box(newValue)
                pthread_setspecific(key, Unmanaged.passRetained(box).toOpaque())
            } else {
                pthread_setspecific(key, nil)
            }
        }
    }

    deinit {
        pthread_key_delete(key)
    }
}

/// 内部值盒子：`passRetained` 交由线程销毁器释放，跨平台统一内存管理。
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
