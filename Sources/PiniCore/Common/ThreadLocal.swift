#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// 跨平台线程本地存储（macOS / Linux 通用）。
///
/// 替代 Foundation 仅 macOS/iOS 提供的 `Thread.current.threadDictionary`，使解释器可在 Linux 编译通过。
/// 底层用 POSIX `pthread_key_t`：每个线程持有一份独立副本；线程退出时由注册销毁器自动释放值盒子，无泄漏。
///
/// 用途：并发任务隔离——每个 `=>` worker 线程维护独立的 `currentEnv` / `deferStack` / `currentFuture` /
/// `debugDepth` / `callStackNames`，互不污染共享解释器状态（D1 修复策略，原以 `threadDictionary` 实现）。
final class ThreadLocal<T> {
 private var key: pthread_key_t

 init() {
 var k = pthread_key_t()
 // 销毁器：线程退出时释放当前线程持有的盒子（匹配下方 set 中的 passRetained）。
 // 用 AnyObject 类型擦除避免捕获泛型 T（否则无法形成 C 函数指针）。
 let destructor: @convention(c) (UnsafeMutableRawPointer) -> Void = { raw in
 Unmanaged<AnyObject>.fromOpaque(raw).release()
 }
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
