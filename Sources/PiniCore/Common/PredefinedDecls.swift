import Foundation

/// 语言预置声明 —— **由宿主给出**的那份声明表。
///
/// 语言里有一批名字既不来自用户源码、也不来自任何被解析的源：它们的声明由宿主提供。
/// 本件是**它们的唯一出处** —— 类型层与降载层都从这里取，⛔ 不各写一份
/// （两份迟早会漂，而漂的那一刻不会有任何一条判据变红）。
///
/// ⭐ **一处接缝，专为自举留的余量**：今天这份声明由 Swift 构造、初值也在 Swift 里定下；
/// 将来若改由 Pini 源提供，**只换本件的内容** —— 取用点、调用方、判据都不动。
/// ⇒ 判据因此只针对「默认实例可取得、且其可观测面读得出」，⛔ 不断言它由谁构造。
///
/// ⚠️ 预置声明的**位置**不是文件位置：它给一个人造名，且**不写成路径形态** ——
/// 写成路径会让人去磁盘上找一份并不存在的文件。
enum PredefinedDecls {

    /// 预置声明的来源标记。
    static let sourceName = "<预置声明>"

    /// 预置声明的**位置**。行列为 0：它不对应任何真实字符。
    static var location: SourceLocation {
        SourceLocation(line: 0, column: 0, fileName: sourceName)
    }

    /// 调度特征的预置给定块 —— 语言提供的**默认调度实例**。
    ///
    /// ⭐ **一个名字两种角色**（实测二者并存、零诊断）：
    /// **特征**是接口（`实现:` 位的可引用对象），**给定块**是默认实例的类型
    /// （取用点只认给定块 —— 只有特征形态时，`using` 形参在降载期解析不出类型）。
    ///
    /// ⛔ **字段表刻意只有一个标识字段，不是遗漏**：策略自身的状态
    /// （队列 · 优先级 · 归约阈值）的形状，依附于「**任务在语言里怎么表示**」这一面，
    /// 而那一面今天还没有载体 ⇒ 在此预置字段等于替一个未决的形状做承诺。
    /// 标识字段只回答一个问题：**取到的是哪一个默认实例**。
    ///
    /// ⛔ **不声明 `实现:` 它自己的特征**：该特征的抽象方法集今天为空，
    /// 此刻声明这条遵循关系**不携带任何内容**。待方法集随任务载体定下时，
    /// 应当**连同默认方法体一起**作一次决定 —— 那时这条遵循关系才有内容可约束。
    static var schedulerGivenBlock: TopLevelDecl {
        let loc = location
        return .givenDecl(
            GivenDecl(
                name: schedulerTypeName,
                genericParams: [],
                fields: [
                    FieldDecl(
                        name: "名称",
                        typeAnnotation: .simple(name: "String", location: loc),
                        initializer: .stringLiteral(value: "默认", location: loc),
                        location: loc
                    )
                ],
                methods: [],
                traits: [],
                location: loc
            )
        )
    }

    /// 调度特征的**语言可见名**。类型层登记的那个特征与上面的给定块同名。
    static let schedulerTypeName = "调度器"

    /// 全部预置声明。两个消费者都从这里取。
    static var all: [TopLevelDecl] { [schedulerGivenBlock] }
}
