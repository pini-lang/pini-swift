import Foundation

/// 跨线程交接盒：把一次性的值交给另一个执行域，读写由调用方自己的锁或信号量串起来。
/// Swift 6 不给「手工保证」留隐式通道，故这里显式声明 —— 声明是手工的，保证也由调用方承担。
final class SendableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
