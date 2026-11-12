import Foundation

/// 内建名的语言面清单：降载层与发射层按它判断「这个名字归内建通道回答」。
/// 执行层用同一批名字建分发表 —— 两处一旦分叉，就会出现「降下来了却没人答」的调用点，
/// 故 `BuiltinSurfaceTests` 逐组比对两张名单。
public enum BuiltinSurface {
    /// 字符内建、临时字节视图与临时数值桥。应答侧是运行时按名分派的字符 shim。
    /// `temp` 前缀标出过渡身份：字节文本模型与 `as` 接管后，这三条入口一并移除。
    public static let character: Set<String> = [
        "chars", "chr", "ord", "is_letter", "is_number", "tempUtf8Bytes",
        "tempByteToInt", "tempIntToByte",
    ]

    /// 普通调用能承载的并发内建：`sleep` 阻塞，`Error` / `CancelError` 造值。
    /// 处理 `Future` 的名字不在内：IR 还表示不了它，白名单与表同进同退。
    public static let synchronousConcurrency: Set<String> = ["sleep", "Error", "CancelError"]
}
