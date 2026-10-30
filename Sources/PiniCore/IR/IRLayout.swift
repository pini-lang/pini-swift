import Foundation

/// 布局事实：值由几个槽组成、每个槽放什么。目标无关 —— 槽不等于字节，每槽取多宽由后端决定。
/// 后端读这里定位字段与载荷，不再自己推；推导写两遍就会漂，而漂移的形态是「读到别处」而非崩溃。
public struct IRLayout: Equatable, Sendable {
    /// 名义箱头槽数：强计数 · 弱计数 · 类型标识 · 弱引用旁表。三族（结构体 / 对象 / 枚举）共用。
    public let headerSlotCount: Int
    /// 枚举用例标签所在槽，紧随头之后。
    public let enumTagSlot: Int
    /// 枚举载荷起始槽，标签之后。
    public let enumPayloadBase: Int
    /// `Result` 的槽数：标签 · ok 载荷 · 错误字。
    public let resultSlotCount: Int
    /// `Optional` 的槽数：标签 · 载荷。
    public let optionalSlotCount: Int

    /// 现行布局。头四槽是 `PiniHeader` 的形状，改头只改这一处。
    public static let standard = IRLayout(
        headerSlotCount: 4,
        enumTagSlot: 4,
        enumPayloadBase: 5,
        resultSlotCount: 3,
        optionalSlotCount: 2
    )

    public init(
        headerSlotCount: Int, enumTagSlot: Int, enumPayloadBase: Int,
        resultSlotCount: Int, optionalSlotCount: Int
    ) {
        self.headerSlotCount = headerSlotCount
        self.enumTagSlot = enumTagSlot
        self.enumPayloadBase = enumPayloadBase
        self.resultSlotCount = resultSlotCount
        self.optionalSlotCount = optionalSlotCount
    }

    /// 第 `index` 个名义字段（声明序，从 0 起）的槽位。
    public func fieldSlot(of index: Int) -> Int {
        headerSlotCount + index
    }

    /// 第 `index` 个枚举载荷的槽位（按该用例关联值的声明序，从 0 起）。
    public func enumPayloadSlot(of index: Int) -> Int {
        enumPayloadBase + index
    }
}
