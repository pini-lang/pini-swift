import Foundation

/// 编译器侧的运行时入口清单：LLVM 后端能发出的每一条 `bk_*` 调用。
/// 每条给四件事：符号名（跨后端的键）· 签名（`declare` 唯一来源）· 族 · 降级点。
public struct BuiltinSpec: Sendable {
    public struct Signature: Sendable {
        public let result: String
        public let parameters: [String]
        public let attributes: String

        public init(result: String, parameters: [String], attributes: String = "") {
            self.result = result
            self.parameters = parameters
            self.attributes = attributes
        }
    }

    public let symbol: String
    public let signature: Signature
    public let family: Family
    public let lowerings: [String]

    /// 声明行：签名只写在这里，调用点的实参表不再手抄第二份。
    public var declaration: String {
        let args = signature.parameters.joined(separator: ", ")
        return "declare \(signature.result) @\(symbol)(\(args))\(signature.attributes)\n"
    }
}

extension BuiltinSpec {
    /// 与运行时 ABI 契约第 2 节的族同名；族是能力声明与缺口登记的粒度。
    public enum Family: String, CaseIterable, Sendable {
        case array, dictionary, set, handle, lazyRef, given, pointer, display, runtime
        case character, string, nominal, io, task, blocking, yielding, scheduler, error
    }
}

/// 降级点写 IR 节点名；节点之外的发射点用尖括号：
/// `<cleanup>` 退出或覆盖 · `<retain>` 落槽 · `<entry>` 入口 · `<print>` 打印。
/// `<panic>` 陷阱 · `<closure>` 捕获槽 · `<frame>` 帧序言 · `<yield>` 让出点。
public enum Builtins {
    public static let all: [BuiltinSpec] = [

        // MARK: array
        BuiltinSpec(
            symbol: "bk_array_append",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .array, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_array_create", signature: .init(result: "ptr", parameters: ["i32"]),
            family: .array, lowerings: ["arrayLiteral", "sliceCall"]
        ),
        BuiltinSpec(
            symbol: "bk_array_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .array, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "bk_array_ensure_unique_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .array, lowerings: ["subscriptGet", "subscriptStore"]
        ),
        BuiltinSpec(
            symbol: "bk_array_get", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .array, lowerings: ["subscriptGet", "forInStmt"]
        ),
        BuiltinSpec(
            symbol: "bk_array_len", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .array, lowerings: ["lenCall", "forInStmt", "subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "bk_array_set",
            signature: .init(result: "ptr", parameters: ["ptr", "i32", "ptr", "i32", "i32"]),
            family: .array, lowerings: ["arrayLiteral", "subscriptStore"]
        ),

        // MARK: dictionary
        BuiltinSpec(
            symbol: "bk_dict_create", signature: .init(result: "ptr", parameters: []),
            family: .dictionary, lowerings: ["dictLiteral"]
        ),
        BuiltinSpec(
            symbol: "bk_dict_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .dictionary, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "bk_dict_ensure_unique_at",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .dictionary, lowerings: ["subscriptGet", "subscriptStore"]
        ),
        BuiltinSpec(
            symbol: "bk_dict_get", signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .dictionary, lowerings: ["subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "bk_dict_key_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .dictionary, lowerings: ["forInStmt"]
        ),
        BuiltinSpec(
            symbol: "bk_dict_len", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .dictionary, lowerings: ["lenCall", "forInStmt"]
        ),
        BuiltinSpec(
            symbol: "bk_dict_set",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32", "ptr", "i32", "i32"]),
            family: .dictionary, lowerings: ["dictLiteral", "subscriptStore"]
        ),
        BuiltinSpec(
            symbol: "bk_dict_val_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .dictionary, lowerings: ["forInStmt"]
        ),

        // MARK: set
        BuiltinSpec(
            symbol: "bk_set_add", signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i32", "i32"]),
            family: .set, lowerings: ["setLiteral"]
        ),
        BuiltinSpec(
            symbol: "bk_set_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .set, lowerings: ["forInStmt"]
        ),
        BuiltinSpec(
            symbol: "bk_set_create", signature: .init(result: "ptr", parameters: []),
            family: .set, lowerings: ["setLiteral"]
        ),
        BuiltinSpec(
            symbol: "bk_set_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .set, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "bk_set_len", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .set, lowerings: ["lenCall", "forInStmt"]
        ),

        // MARK: handle
        BuiltinSpec(
            symbol: "bk_handle_ensure_unique", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .handle, lowerings: ["subscriptStore", "fieldStore"]
        ),
        BuiltinSpec(
            symbol: "bk_handle_release", signature: .init(result: "void", parameters: ["ptr"]),
            family: .handle, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "bk_handle_retain", signature: .init(result: "void", parameters: ["ptr"]),
            family: .handle, lowerings: ["<retain>"]
        ),

        // MARK: lazyRef
        BuiltinSpec(
            symbol: "bk_lazyref_create",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "ptr", "i32", "i32"]),
            family: .lazyRef, lowerings: ["lazyRefConstruct"]
        ),
        BuiltinSpec(
            symbol: "bk_lazyref_destroy", signature: .init(result: "void", parameters: ["ptr"]),
            family: .lazyRef, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "bk_lazyref_value", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .lazyRef, lowerings: ["lazyRefValue"]
        ),

        // MARK: given
        BuiltinSpec(
            symbol: "bk_given_get", signature: .init(result: "ptr", parameters: ["ptr", "ptr", "i64"]),
            family: .given, lowerings: ["givenInstance", "fieldGet"]
        ),

        // MARK: display
        BuiltinSpec(
            symbol: "bk_cstr", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .display, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_double_to_string", signature: .init(result: "ptr", parameters: ["double"]),
            family: .display, lowerings: ["<print>"]
        ),
        BuiltinSpec(
            symbol: "bk_panic",
            signature: .init(result: "void", parameters: ["ptr"], attributes: " noreturn"),
            family: .display, lowerings: ["<panic>"]
        ),

        // MARK: character
        BuiltinSpec(
            symbol: "bk_chars", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_chr", signature: .init(result: "ptr", parameters: ["i32"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_is_letter", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_is_number", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .character, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_ord", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .character, lowerings: ["call"]
        ),

        // MARK: string
        BuiltinSpec(
            symbol: "bk_str_alloc", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .string, lowerings: ["stringConcat"]
        ),
        BuiltinSpec(
            symbol: "bk_str_dup", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["interpString", "arrayJoin"]
        ),
        BuiltinSpec(
            symbol: "bk_str_release", signature: .init(result: "void", parameters: ["ptr"]),
            family: .string, lowerings: ["<cleanup>", "<print>"]
        ),
        BuiltinSpec(
            symbol: "bk_str_retain", signature: .init(result: "void", parameters: ["ptr"]),
            family: .string, lowerings: ["<retain>"]
        ),
        BuiltinSpec(
            symbol: "bk_string_char_at", signature: .init(result: "ptr", parameters: ["ptr", "i32"]),
            family: .string, lowerings: ["subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "bk_string_contains", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .string, lowerings: ["stringContains"]
        ),
        BuiltinSpec(
            symbol: "bk_string_count", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .string, lowerings: ["lenCall", "subscriptGet"]
        ),
        BuiltinSpec(
            symbol: "bk_string_index_of", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .string, lowerings: ["stringIndexOf"]
        ),
        BuiltinSpec(
            symbol: "bk_string_lower", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringCase"]
        ),
        BuiltinSpec(
            symbol: "bk_string_slice",
            signature: .init(result: "ptr", parameters: ["ptr", "i32", "i32", "i32", "i32"]),
            family: .string, lowerings: ["sliceCall"]
        ),
        BuiltinSpec(
            symbol: "bk_string_split", signature: .init(result: "ptr", parameters: ["ptr", "ptr"]),
            family: .string, lowerings: ["stringSplit"]
        ),
        BuiltinSpec(
            symbol: "bk_string_trim_left", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringTrimLeft"]
        ),
        BuiltinSpec(
            symbol: "bk_string_trim_right", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringTrimRight"]
        ),
        BuiltinSpec(
            symbol: "bk_string_upper", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .string, lowerings: ["stringCase"]
        ),
        BuiltinSpec(
            symbol: "bk_substring", signature: .init(result: "ptr", parameters: ["ptr", "i32", "i32"]),
            family: .string, lowerings: ["stringSubstring"]
        ),

        // MARK: nominal
        BuiltinSpec(
            symbol: "bk_nominal_alloc", signature: .init(result: "ptr", parameters: ["i64", "i32"]),
            family: .nominal, lowerings: ["construct", "enumConstruct"]
        ),
        BuiltinSpec(
            symbol: "bk_nominal_release", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .nominal, lowerings: ["<cleanup>"]
        ),
        BuiltinSpec(
            symbol: "bk_nominal_retain", signature: .init(result: "void", parameters: ["ptr"]),
            family: .nominal, lowerings: ["<retain>"]
        ),
        BuiltinSpec(
            symbol: "bk_slot_alloc", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .nominal, lowerings: ["<closure>"]
        ),

        // MARK: io
        BuiltinSpec(
            symbol: "bk_append_file", signature: .init(result: "void", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileAppend"]
        ),
        BuiltinSpec(
            symbol: "bk_argv", signature: .init(result: "ptr", parameters: []),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_exists", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_is_dir", signature: .init(result: "i32", parameters: ["ptr"]),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_list_dir", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_module_root", signature: .init(result: "ptr", parameters: []),
            family: .io, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_read_file", signature: .init(result: "ptr", parameters: ["ptr"]),
            family: .io, lowerings: ["fileRead"]
        ),
        BuiltinSpec(
            symbol: "bk_set_program_base", signature: .init(result: "void", parameters: ["ptr"]),
            family: .io, lowerings: ["<entry>"]
        ),
        BuiltinSpec(
            symbol: "bk_try_append_file", signature: .init(result: "i64", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileTryAppend"]
        ),
        BuiltinSpec(
            symbol: "bk_try_read_file", signature: .init(result: "ptr", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileTryRead"]
        ),
        BuiltinSpec(
            symbol: "bk_try_write_file", signature: .init(result: "i64", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileTryWrite"]
        ),
        BuiltinSpec(
            symbol: "bk_write_file", signature: .init(result: "void", parameters: ["ptr", "ptr"]),
            family: .io, lowerings: ["fileWrite"]
        ),

        // MARK: task
        BuiltinSpec(
            symbol: "bk_task_cancel", signature: .init(result: "void", parameters: ["ptr"]),
            family: .task, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_task_detach", signature: .init(result: "void", parameters: ["ptr"]),
            family: .task, lowerings: ["detachStmt"]
        ),
        BuiltinSpec(
            symbol: "bk_task_join", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .task, lowerings: ["join"]
        ),
        BuiltinSpec(
            symbol: "bk_task_spawn",
            signature: .init(result: "ptr", parameters: ["ptr", "ptr", "ptr", "i32", "i32"]),
            family: .task, lowerings: ["call"]
        ),

        // MARK: blocking
        BuiltinSpec(
            symbol: "bk_sleep", signature: .init(result: "void", parameters: ["i32"]),
            family: .blocking, lowerings: ["call"]
        ),

        // MARK: yielding
        BuiltinSpec(
            symbol: "bk_task_await", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .yielding, lowerings: ["<yield>"]
        ),
        BuiltinSpec(
            symbol: "bk_task_frame", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .yielding, lowerings: ["<frame>", "call"]
        ),
        BuiltinSpec(
            symbol: "bk_task_slot", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .yielding, lowerings: ["<frame>"]
        ),

        // MARK: scheduler
        BuiltinSpec(
            symbol: "bk_task_bind_sched", signature: .init(result: "i32", parameters: ["ptr", "ptr"]),
            family: .scheduler, lowerings: ["<entry>"]
        ),

        // MARK: error
        BuiltinSpec(
            symbol: "bk_cancel_error_create", signature: .init(result: "i64", parameters: ["ptr"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_error_create", signature: .init(result: "i64", parameters: ["ptr"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_error_is_cancel", signature: .init(result: "i32", parameters: ["i64"]),
            family: .error, lowerings: ["call"]
        ),
        BuiltinSpec(
            symbol: "bk_error_message", signature: .init(result: "ptr", parameters: ["i64"]),
            family: .error, lowerings: ["call"]
        ),
    ]

    private static let bySymbol: [String: BuiltinSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.symbol, $0) })

    public static func spec(for symbol: String) -> BuiltinSpec? { bySymbol[symbol] }

    /// 发射一条 `declare`；查不到即停 —— 静默跳过会产出「调用无声明」的模块。
    public static func declaration(for symbol: String) -> String {
        guard let spec = bySymbol[symbol] else {
            preconditionFailure("Builtins: \(symbol) 不在清单里；先登记再发声明")
        }
        return spec.declaration
    }
}
