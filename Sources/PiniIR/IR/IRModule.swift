import Foundation
import PiniSemantics

/// 降载后的函数。`returnType` 为 nil 表示 void；切片集合至多允许一个标量返回类型
/// （元组返回尚未纳入）。
public struct IRFunction: Equatable {
    public let name: String
    public let params: [IRParam]
    public let returnType: IRType?
    public let body: IRBlock
    /// `=>` 调度：函数体在工作线程上跑，调用方拿到的是未决的 `Future`，不是函数体的返回值。
    /// 该标记留在被调方而不从 `returnType` 反推：调用节点带的是函数体协议而非签名，
    /// 且未标注形参根本没有类型 —— 类型答不出这个问题。
    public let isAsync: Bool
    /// `|test`：这个块是语言级测试用例而非被调函数，`pini test` 只收集它、也只收集它。
    /// 该事实必须进 IR，因为收集规则长在 `FuncDecl.modifiers` 上而它在 IR 没有对应物；
    /// 名字不能替代 —— 程序完全可以写一个叫 `测试` 的正式函数。
    public let isTest: Bool
    /// 声明该函数的文件。`lower(package:)` 把各文件的声明并进一个虚拟模块，合并会抹掉来源，
    /// 而 `pini test <path>` 要按文件收窄，故合并后的模块必须留着它，否则收窄无从谈起。
    public let sourceFile: String
    /// 本函数的物化依赖：函数体里出现的默认实例取用所指向的给定块类型，降载时逐点收集
    /// （`FunctionContext.givenReferenceNames`）后在构造时取出。留痕是给后置的环检测用的
    /// （`IRModule.givenReferences`），本期不产任何诊断。
    public let givenReferenceNames: Set<String>
    /// 本函数体直接调用的函数名（IR 名），降载时逐点收集，含方法调用。环检测靠它穿透普通函数：
    /// 没有「函数 → 函数」这条边，字段初值经中间函数绕回来的环就走不通。
    public let calledFunctionNames: Set<String>
    /// 源码里的写法（`类型.方法`），只在它与 `name` 不同时给出 —— 方法在 IR 里是 mangle 过的
    /// `方法__类型`（`点` → `_u70B9`）。空串表示与 `name` 同名，顶层函数即如此。
    public let displayName: String

    public struct IRParam: Equatable {
        public let name: String
        public let type: IRType
        /// AST 面 `Parameter.isUsing` 的随行者：与 `isAsync` / `isTest` / `sourceFile` 同族——AST 上有的字段 IR 必须随行，
        /// 否则降载是首个丢失它的地方，后端再也问不出「这个参数是谁提供的」。
        /// 目前只做携带：物化与强制规则属后续，故它今天没有消费点。
        public let isUsing: Bool
        public init(name: String, type: IRType, isUsing: Bool = false) {
            self.name = name
            self.type = type
            self.isUsing = isUsing
        }
    }

    public init(
        name: String, params: [IRParam], returnType: IRType?, body: IRBlock,
        isAsync: Bool = false, isTest: Bool = false, sourceFile: String = "",
        givenReferenceNames: Set<String> = [], calledFunctionNames: Set<String> = [],
        displayName: String = ""
    ) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.body = body
        self.isAsync = isAsync
        self.isTest = isTest
        self.givenReferenceNames = givenReferenceNames
        self.calledFunctionNames = calledFunctionNames
        self.displayName = displayName
        self.sourceFile = sourceFile
    }
}

/// 一个枚举用例：按声明顺序的 tag 加带类型的关联值。
public struct IREnumCase: Equatable {
    public let name: String
    public let tag: Int
    /// 关联形参名（`nil` 表示按位置声明），与 `payloadTypes` 一一对应。
    /// 带标签的构造实参靠它解析。
    public let paramNames: [String?]
    public let payloadTypes: [IRType]

    public init(name: String, tag: Int, paramNames: [String?], payloadTypes: [IRType]) {
        self.name = name
        self.tag = tag
        self.paramNames = paramNames
        self.payloadTypes = payloadTypes
    }
}

/// 降载后的枚举声明：标签联合布局，发射器出
/// `%enum.Name = type { i32, <最大元数用例的载荷类型> }`。
public struct IREnumDecl: Equatable {
    public let name: String
    public let cases: [IREnumCase]

    public init(name: String, cases: [IREnumCase]) {
        self.name = name
        self.cases = cases
    }

    /// 最大元数用例的载荷类型（联合的槽布局）。
    public var slotTypes: [IRType] {
        cases.max { $0.payloadTypes.count < $1.payloadTypes.count }?.payloadTypes ?? []
    }
}

/// 一条 foreign 函数绑定（FFI 子系统）：`[库|foreign]` 块里只要签名、不要体的条目。
/// 发射器转发它的 declare；调用点就是一次普通 `.call`，经签名表解析。
/// 签名只用 `FFIType`：闭合集之外的类型到不了这里，两个通道读的是同一份判据。
public struct IRForeignFunction: Equatable {
    public let name: String
    public let params: [FFIType]
    public let returnType: FFIType?
    /// C 变参：`params` 是固定前缀，调用点可以多传。多传的实参在发射层做默认实参提升，
    /// 解释器没有 C 变参 ABI，遇到即拒绝。
    public let isVariadic: Bool

    public init(name: String, params: [FFIType], returnType: FFIType?, isVariadic: Bool = false) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.isVariadic = isVariadic
    }
}

extension FFIType {
    /// 值面拼写：`cString` 与 `String` 同为 `i8*`，调用点与 declare 因此对得上。
    /// 指针统一 `ptr`；标量与 `IRType` 同宽。回调是 `cFunction` —— 与 Pini 函数值的 `{ptr, ptr}` 分开。
    public var irType: IRType {
        switch self {
        case .i8: return .i8
        case .u8: return .u8
        case .i32: return .i32
        case .i64: return .i64
        case .u64: return .u64
        case .f64: return .f64
        case .boolean: return .boolean
        case .pointer(let target): return .pointer(element: target.irType)
        case .cString: return .string
        case .callback(let params, let returnType):
            return .cFunction(
                params: params.map { $0.irType }, returnType: returnType?.irType)
        /// 句柄有自己的 IR 类型：与 `*U8` 同为 `ptr` 拼写，但语言层不能互传（`load` / `fromCString` 都不收它）。
        case .stringHandle: return .stringHandle
        }
    }
}

/// 一个外部数据符号：名字即符号名，`type` 是该存储的静态类型。
/// `readonly` 只是一条写侧禁令，进 IR 是为了让发射层区分可写与只读，链接期无判据。
public struct IRForeignData: Equatable {
    public let name: String
    public let type: IRType
    public let isReadonly: Bool

    public init(name: String, type: IRType, isReadonly: Bool) {
        self.name = name
        self.type = type
        self.isReadonly = isReadonly
    }
}

/// 宏常量的构建期值。它没有存储：读它就是读这个字面量，取址无从谈起。
public enum IRForeignConstantValue: Equatable {
    case integer(Int)
    case float(Double)
}

/// 一条宏常量：名字、声明类型、构建期求出的值。
public struct IRForeignConstant: Equatable {
    public let name: String
    public let type: IRType
    public let value: IRForeignConstantValue

    public init(name: String, type: IRType, value: IRForeignConstantValue) {
        self.name = name
        self.type = type
        self.value = value
    }
}

/// 降载后的 foreign 块：组名（`[libc|foreign]` 里 `|` 左侧的标签）加它的纯签名绑定。
/// 符号解析在解释器 / ffi 侧完成（先查 shim 白名单再 dlsym）；IR 层只承载 declare 面。
public struct IRForeignBlock: Equatable {
    public let name: String
    public let funcs: [IRForeignFunction]
    /// 数据符号：`名: 类型` 条目，读、取址、写都落到这一张表上。
    public let data: [IRForeignData]
    /// 宏常量：`名|macro: 类型` 条目，值在构建期由 C 预处理器给出。
    public let constants: [IRForeignConstant]

    public init(
        name: String, funcs: [IRForeignFunction], data: [IRForeignData] = [],
        constants: [IRForeignConstant] = []
    ) {
        self.name = name
        self.funcs = funcs
        self.data = data
        self.constants = constants
    }
}

/// 一个导出形参：`isUsing` 位不进 C 原型，由转发层在边界内用默认实例填。
/// 顺序即 Pini 函数的形参顺序，转发层照它排实参。
public struct IRExportParam: Equatable {
    public let type: IRType
    public let isUsing: Bool

    public init(type: IRType, isUsing: Bool) {
        self.type = type
        self.isUsing = isUsing
    }
}

/// 一个 C 导出函数项：C 名、Pini 名、形参计划与返回。
/// `returnType` 为 `.result` 时按「状态码 + 出参」发布，头文件与发射层读同一条判据。
public struct IRExportFunction: Equatable {
    public let cName: String
    public let pinName: String
    public let params: [IRExportParam]
    public let returnType: IRType?

    public init(cName: String, pinName: String, params: [IRExportParam], returnType: IRType?) {
        self.cName = cName
        self.pinName = pinName
        self.params = params
        self.returnType = returnType
    }

    /// C 原型上的形参：取用位不在其中。
    public var cParamTypes: [IRType] {
        params.filter { !$0.isUsing }.map(\.type)
    }

    /// `^T` 的载荷：非 nil 即 C 侧看到 `int32_t f(..., T* out)`，0 成功、1 失败。
    public var statusPayload: IRType? {
        guard case .result(let ok)? = returnType else { return nil }
        return ok
    }
}

/// 一个 C 导出的给定块：结构体只镜像字段区，取址函数返回它的首地址。
/// 字段名已转写为 C 标识符，后端不再改名。
public struct IRExportStorage: Equatable {
    public struct Field: Equatable {
        public let name: String
        public let type: IRType

        public init(name: String, type: IRType) {
            self.name = name
            self.type = type
        }
    }

    public let cName: String
    public let typeName: String
    public let fields: [Field]
    public let getterName: String

    public init(cName: String, typeName: String, fields: [Field], getterName: String) {
        self.cName = cName
        self.typeName = typeName
        self.fields = fields
        self.getterName = getterName
    }
}

/// export 块 `|c` 条目的落地形态：函数转发项、给定块取址项、错误码表，以及两个生成的生命周期符号。
/// 名字取文件名，产物与这两个符号据此命名，不参与条目符号名。
public struct IRExportBlock: Equatable {
    public let name: String
    public let functions: [IRExportFunction]
    public let storages: [IRExportStorage]
    /// C 边界的错误码表：派生、手写、自动三种来源同处一张表。
    public let errorCodes: [PiniErrorCode]
    public let initName: String
    public let shutdownName: String

    public init(
        name: String, functions: [IRExportFunction], storages: [IRExportStorage],
        errorCodes: [PiniErrorCode] = [],
        initName: String, shutdownName: String
    ) {
        self.name = name
        self.functions = functions
        self.storages = storages
        self.errorCodes = errorCodes
        self.initName = initName
        self.shutdownName = shutdownName
    }
}

/// 降载后的模块：有序的函数，加名义类型与枚举声明。入口函数是 `main`（切片发射器要求）；
/// 方法存在各自的 `IRTypeDecl` 里，按普通函数发射。
public struct IRModule: Equatable {
    public let functions: [IRFunction]
    public let types: [IRTypeDecl]
    public let enums: [IREnumDecl]
    /// foreign 块：只有 declare 面，没有函数体。
    public let foreigns: [IRForeignBlock]

    /// C 面：至多一块，条目名字已转成 C 标识符。
    public let export: IRExportBlock?

    /// 布局事实：名义头、字段与载荷各在第几槽。后端只读不算 —— 契约第 5 节「布局归位」。
    public let layout: IRLayout

    /// 谁引用了哪个给定块：键是引用方（函数名 / 给定块名），值是它引用的给定块类型名（升序去重）。
    /// 引用面 = 函数体里的默认实例取用点 + 给定块字段初值里的引用；只覆盖**直接取用**，且方法体不在表内
    /// （方法不进 `functions`）。这是可观测面而非诊断：环检测读它，留痕当期就要做对。
    public let givenReferences: [String: [String]]

    /// 谁调用了哪个顶层函数：键是调用方（函数名 / 给定块名），值是它直接调用的函数名（升序去重）。
    /// 与 `givenReferences` 分表是刻意的：那张表的值面恒为给定块，环检测据此判定「哪些节点是给定块」，
    /// 混进函数名会让这条判据失效。
    public let callReferences: [String: [String]]

    public init(
        functions: [IRFunction], types: [IRTypeDecl] = [], enums: [IREnumDecl] = [],
        foreigns: [IRForeignBlock] = [], export: IRExportBlock? = nil, layout: IRLayout = .standard,
        givenReferences: [String: [String]] = [:], callReferences: [String: [String]] = [:]
    ) {
        self.functions = functions
        self.types = types
        self.enums = enums
        self.foreigns = foreigns
        self.export = export
        self.layout = layout
        self.givenReferences = givenReferences
        self.callReferences = callReferences
    }

    public func function(named name: String) -> IRFunction? {
        functions.first { $0.name == name }
    }

    /// IR 名 → 源码写法，只收两者不同的那些。诊断层拿它把 mangle 过的名字还原成 `类型.方法`；
    /// 分不清的（顶层函数）没有条目，按名直出即可。
    public var displayNames: [String: String] {
        var labels: [String: String] = [:]
        for function in functions where !function.displayName.isEmpty {
            labels[function.name] = function.displayName
        }
        for decl in types {
            for method in decl.methods where !method.displayName.isEmpty {
                labels[method.name] = method.displayName
            }
        }
        return labels
    }

    public var mainFunction: IRFunction? {
        function(named: "main")
    }
}
