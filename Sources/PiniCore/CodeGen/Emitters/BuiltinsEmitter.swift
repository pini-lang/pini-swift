import Foundation

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 内建函数发射：数学（abs/min/max/三角）、IO（readLine/readFile/writeFile）、
/// 字符串方法（contains/大小写/substring/split）、数组 join、len 求值。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 // MARK: - 内置数学函数（P6-4b）

 func generateBuiltinAbs(_ arguments: [CallArgument]) throws -> IRValue {
 guard let arg = arguments.first else { throw IRGenError.unsupportedExpression(kind:"abs requires 1 arg", sl()) }
 let val = try generateExpression(arg.expression)
 guard val.llvmType == "i32" else { throw IRGenError.unsupportedExpression(kind:"abs expects i32", sl()) }
 let neg = "%t\(nextTemp())"
 emitLine(" \(neg) = sub i32 0, \(val.ssaName)")
 let cond = "%t\(nextTemp())"
 emitLine(" \(cond) = icmp slt i32 \(val.ssaName), 0")
 let res = "%t\(nextTemp())"
 emitLine(" \(res) = select i1 \(cond), i32 \(neg), i32 \(val.ssaName)")
 return IRValue(llvmType: "i32", ssaName: res)
 }

 func generateBuiltinMinMax(isMin: Bool, _ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count == 2 else { throw IRGenError.unsupportedExpression(kind:"min/max requires 2 args", sl()) }
 let a = try generateExpression(arguments[0].expression)
 let b = try generateExpression(arguments[1].expression)
 guard a.llvmType == "i32", b.llvmType == "i32" else { throw IRGenError.unsupportedExpression(kind:"min/max expects i32", sl()) }
 let cond = "%t\(nextTemp())"
 let cmp = isMin ? "slt" : "sgt"
 emitLine(" \(cond) = icmp \(cmp) i32 \(a.ssaName), \(b.ssaName)")
 let res = "%t\(nextTemp())"
 emitLine(" \(res) = select i1 \(cond), i32 \(a.ssaName), i32 \(b.ssaName)")
 return IRValue(llvmType: "i32", ssaName: res)
 }

 func generateBuiltinReadLine() throws -> IRValue {
 let bufSize = 256
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[\(bufSize) x i8]"))
 let bufPtr = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: bufPtr, aggregate: "[\(bufSize) x i8]", base: buf, indices: [0, 0]))
 let stdinPtr = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: stdinPtr, type: "ptr", ptr: "@__stdinp"))
 let result = "%t\(nextTemp())"
 emitLine(" \(result) = call ptr @fgets(ptr \(bufPtr), i32 \(bufSize), ptr \(stdinPtr))")
 return IRValue(llvmType: "ptr", ssaName: result)
 }

 /// #46-E G41（test 块，R2）：assert 内建 LLVM 发射。
 ///
 /// 签名：`assert(条件: Bool,)` / `assert(条件: Bool, 消息: String,)`。
 /// 条件为 i1；false 时经 `@bk_panic(ptr 消息)` 打印消息到 stderr 并 abort（不返回，
 /// 与解释器抛 RuntimeError 的「以错误终止」语义对齐，见 ADR-008 ）。
 /// 消息缺省用模块级常量 "assert failed"；带消息参数时直接复用（字符串本就是 C 串 ptr）。
 func generateBuiltinAssert(_ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count >= 1, arguments.count <= 2 else {
 throw IRGenError.unsupportedExpression(kind:"assert requires 1 or 2 args (condition, message?)", sl())
 }
 usesAssert = true
 let cond = try generateExpression(arguments[0].expression)
 guard cond.llvmType == "i1" else {
 throw IRGenError.unsupportedExpression(kind:"assert 参数 1 必须是 Bool（收到 \(cond.llvmType)）", sl())
 }
 let msg: IRValue
 if arguments.count == 2 {
 msg = try generateExpression(arguments[1].expression)
 guard msg.llvmType == "ptr" else {
 throw IRGenError.unsupportedExpression(kind:"assert 参数 2 必须是 String（收到 \(msg.llvmType)）", sl())
 }
 } else {
 msg = try generateStringLiteral("assert failed")
 }
 let okLabel = "assert_ok_\(nextTemp())"
 let failLabel = "assert_fail_\(nextTemp())"
 emitLine(" br i1 \(cond.ssaName), label %\(okLabel), label %\(failLabel)")
 emitLine("\(failLabel):")
 emitLine(" call void @bk_panic(ptr \(msg.ssaName))")
 emitLine(" unreachable")
 emitLine("\(okLabel):")
 return IRValue(llvmType: "void", ssaName: "void")
 }

 // MARK: - #46-E G40（S3 LLVM 端）：LazyRef 构造与 `.value` 发射

 /// `LazyRef<T>(初始化闭包)` 发射：生成类型特化 wrapper（闭包结果装箱为 box ptr）→
 /// `bk_lazyref_create(code, env, bytes, tag)` → `%bk_lazyref*` 句柄。
 func generateLazyRefConstruct(typeArgs: [TypeAnnotation], arguments: [CallArgument]) throws -> IRValue {
 guard typeArgs.count == 1 else {
 throw IRGenError.unsupportedExpression(kind:"LazyRef requires 1 type arg", sl())
 }
 guard arguments.count == 1 else {
 throw IRGenError.unsupportedExpression(kind:"LazyRef requires 1 arg (initializer closure)", sl())
 }
 let elemIR = try typeMapper.map(typeArgs[0])
 let (bytes, tag) = try lazyRefElemInfo(elemIR)
 usesLazyRef = true
 // 闭包 fat pointer { code, env }
 let closure = try generateCallArgumentValue(arguments[0].expression)
 guard closure.llvmType == "{ ptr, ptr }" else {
 throw IRGenError.unsupportedExpression(kind:"LazyRef 参数必须是初始化闭包（函数值），收到 \(closure.llvmType)", sl())
 }
 let code = "%t\(nextTemp())"
 emitLine(" \(code) = extractvalue { ptr, ptr } \(closure.ssaName), 0")
 let env = "%t\(nextTemp())"
 emitLine(" \(env) = extractvalue { ptr, ptr } \(closure.ssaName), 1")
 try ensureLazyRefWrapper(elemIR: elemIR)
 // create(wrapper, code, env, bytes, tag)：wrapper 是类型特化装箱函数（统一 ptr ABI），
 // code 是闭包 code（wrapper 内部调用）；value 时运行时调 wrapper(code, env, out)。
 let h = "%t\(nextTemp())"
 emitLine(" \(h) = call ptr @bk_lazyref_create(ptr @__lazyref_wrapper_\(lazyRefSuffix(elemIR)), ptr \(code), ptr \(env), i32 \(bytes), i32 \(tag))")
 let typed = "%t\(nextTemp())"
 emitLine(" \(typed) = bitcast ptr \(h) to %bk_lazyref*")
 return IRValue(llvmType: "%bk_lazyref*", ssaName: typed)
 }

 /// `.value` 发射：`bk_lazyref_value(handle)` → 元素 box ptr（调用方按元素 IR 类型 `load T`）。
 func generateLazyRefValue(handle: IRValue) throws -> IRValue {
 usesLazyRef = true
 let raw = "%t\(nextTemp())"
 emitLine(" \(raw) = bitcast \(handle.llvmType) \(handle.ssaName) to ptr")
 let box = "%t\(nextTemp())"
 emitLine(" \(box) = call ptr @bk_lazyref_value(ptr \(raw))")
 return IRValue(llvmType: "ptr", ssaName: box)
 }

 /// LazyRef 元素 box 信息：字节宽度 + 类型标签（与 `_BkTag` 对齐）。
 private func lazyRefElemInfo(_ irType: String) throws -> (bytes: Int, tag: Int32) {
 switch irType {
 case "i32": return (4, 0)
 case "double": return (8, 1)
 case "i1": return (1, 2)
 case "ptr": return (8, 4)
 default:
 throw IRGenError.unsupportedExpression(kind:"LazyRef 暂不支持元素类型 \(irType)（支持 I32/F64/Bool/String）", sl())
 }
 }

 private func lazyRefSuffix(_ irType: String) -> String {
 switch irType {
 case "i32": return "i32"
 case "double": return "f64"
 case "i1": return "i1"
 case "ptr": return "ptr"
 default: return irType.replacingOccurrences(of: " ", with: "_")
 }
 }

 /// 类型特化 wrapper：`define ptr @__lazyref_wrapper_<T>(ptr %code, ptr %env, ptr %out)`——
 /// 调 `code(env)` 得 T，**写入调用方提供的输出 box**（%out）并返回 %out。
 /// 输出 box 由运行时在 `bk_lazyref_value` 中分配（堆），避免「wrapper 内 alloca 返回栈地址」逃逸 UB。
 /// 去重：同一元素 IR 类型只生成一次。
 func ensureLazyRefWrapper(elemIR: String) throws {
 guard !lazyrefWrapperSet.contains(elemIR) else { return }
 lazyrefWrapperSet.insert(elemIR)
 let suffix = lazyRefSuffix(elemIR)
 let storeType = elemIR
 lazyrefWrappersIR += """
define ptr @__lazyref_wrapper_\(suffix)(ptr %code, ptr %env, ptr %out) {
 %val = call \(storeType) %code(ptr %env)
 store \(storeType) %val, \(storeType)* %out
 ret ptr %out
}

"""
 }

 /// 批 5（G58，D-4）：IO 路径实参处理——**无前缀相对路径的字面量**在编译期烘焙程序基准前缀
 /// （`programBase + "/" + 路径`），与解释器三段式方案 A 一致；`./` `../` 开头与绝对路径原样
 /// （运行时 CWD / 原样）；非字面量（变量/插值）无法烘焙，运行时按 CWD 解析（v1 已知限制）。
 func generateIOPathArgument(_ arguments: [CallArgument], index: Int) throws -> IRValue {
 if case .stringLiteral(let value, _) = arguments[index].expression,
 let base = programBase,
 !value.hasPrefix("/"), !value.hasPrefix("./"), !value.hasPrefix("../") {
 return try generateStringLiteral(base + "/" + value)
 }
 return try generateExpression(arguments[index].expression)
 }

 func generateBuiltinWriteFile(_ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count == 2 else { throw IRGenError.unsupportedExpression(kind:"writeFile requires 2 args (path, content)", sl()) }
 let path = try generateIOPathArgument(arguments, index: 0)
 let content = try generateExpression(arguments[1].expression)
 // fopen(path, "w")
 let wMode = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: wMode, aggregate: "[2 x i8]", base: "@.fopen_w", indices: [0, 0]))
 let fp = "%t\(nextTemp())"
 emitLine(" \(fp) = call ptr @fopen(ptr \(path.ssaName), ptr \(wMode))")
 // strlen(content)
 let clen = "%t\(nextTemp())"
 emitLine(" \(clen) = call i64 @strlen(ptr \(content.ssaName))")
 // fwrite(content, 1, len, fp)
 let wret = "%t\(nextTemp())"
 emitLine(" \(wret) = call i64 @fwrite(ptr \(content.ssaName), i64 1, i64 \(clen), ptr \(fp))")
 // fclose(fp)
 let cret = "%t\(nextTemp())"
 emitLine(" \(cret) = call i32 @fclose(ptr \(fp))")
 return IRValue(llvmType: "i32", ssaName: cret)
 }

 func generateBuiltinReadFile(_ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count == 1 else { throw IRGenError.unsupportedExpression(kind:"readFile requires 1 arg (path)", sl()) }
 let path = try generateIOPathArgument(arguments, index: 0)
 // fopen(path, "r")
 let rMode = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: rMode, aggregate: "[2 x i8]", base: "@.fopen_r", indices: [0, 0]))
 let fp = "%t\(nextTemp())"
 emitLine(" \(fp) = call ptr @fopen(ptr \(path.ssaName), ptr \(rMode))")
 // alloca 64KB 缓冲区（LLI JIT 下 fseek/ftell/malloc/fstat 均不可靠；
 // 实际使用中绝大多数源文件/配置文件不超过此限制）
 let bufSize = 65536
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[\(bufSize) x i8]"))
 let bufPtr = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: bufPtr, aggregate: "[\(bufSize) x i8]", base: buf, indices: [0, 0]))
 // fread(buf, 1, 4096, fp)
 let n = "%t\(nextTemp())"
 emitLine(" \(n) = call i64 @fread(ptr \(bufPtr), i64 1, i64 \(bufSize), ptr \(fp))")
 // null terminate: bufPtr[n] = 0
 let last = "%t\(nextTemp())"
 emitLine(builder.fmtGEPByteOffset(name: last, base: bufPtr, offset: n, offsetType: "i64"))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: last))
 // fclose(fp)
 let cret = "%t\(nextTemp())"
 emitLine(" \(cret) = call i32 @fclose(ptr \(fp))")
 return IRValue(llvmType: "ptr", ssaName: bufPtr)
 }

 func generateMathIntrinsic(_ name: String, _ arguments: [CallArgument]) throws -> IRValue {
 guard let arg = arguments.first else { throw IRGenError.unsupportedExpression(kind:"\(name) requires 1 arg", sl()) }
 let val = try generateExpression(arg.expression)
 guard val.llvmType == "double" else { throw IRGenError.unsupportedExpression(kind:"\(name) expects F64", sl()) }
 let res = "%t\(nextTemp())"
 emitLine(" \(res) = call double @llvm.\(name).f64(double \(val.ssaName))")
 return IRValue(llvmType: "double", ssaName: res)
 }

 func generateBuiltinTan(_ arguments: [CallArgument]) throws -> IRValue {
 guard let arg = arguments.first else { throw IRGenError.unsupportedExpression(kind:"tan requires 1 arg", sl()) }
 let val = try generateExpression(arg.expression)
 guard val.llvmType == "double" else { throw IRGenError.unsupportedExpression(kind:"tan expects F64", sl()) }
 let s = "%t\(nextTemp())"
 emitLine(" \(s) = call double @llvm.sin.f64(double \(val.ssaName))")
 let c = "%t\(nextTemp())"
 emitLine(" \(c) = call double @llvm.cos.f64(double \(val.ssaName))")
 let res = "%t\(nextTemp())"
 emitLine(" \(res) = fdiv double \(s), \(c)")
 return IRValue(llvmType: "double", ssaName: res)
 }

 func generateStringContains(_ haystack: String, _ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count == 1 else { throw IRGenError.unsupportedExpression(kind:"contains requires 1 arg", sl()) }
 let needle = try generateExpression(arguments[0].expression)
 let r = "%t\(nextTemp())"
 emitLine(" \(r) = call ptr @strstr(ptr \(haystack), ptr \(needle.ssaName))")
 let c = "%t\(nextTemp())"
 emitLine(" \(c) = icmp ne ptr \(r), null")
 return IRValue(llvmType: "i1", ssaName: c)
 }

 func generateStringCase(isUpper: Bool, str: String) throws -> IRValue {
 let funcName = isUpper ? "toupper" : "tolower"
 let loopLbl = nextLabel()
 let loopHdr = "strcase_hdr_\(loopLbl)"
 let loopBdy = "strcase_bdy_\(loopLbl)"
 let loopEnd = "strcase_end_\(loopLbl)"
 // 复制字符串（避免原地修改影响后续使用）
 let clen = "%t\(nextTemp())"
 emitLine(" \(clen) = call i64 @strlen(ptr \(str))")
 let sz1 = "%t\(nextTemp())"
 emitLine(" \(sz1) = add i64 \(clen), 1")
 let copyBuf = "%t\(nextTemp())"
 emitLine(" \(copyBuf) = alloca i8, i64 \(sz1)")
 let cpret = "%t\(nextTemp())"
 emitLine(" \(cpret) = call ptr @memcpy(ptr \(copyBuf), ptr \(str), i64 \(sz1))")
 // 可变指针：用 alloca ptr 避免 PHI 节点
 let slot = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: slot, type: "ptr"))
 emitLine(builder.fmtStore(value: copyBuf, type: "ptr", ptr: slot))
 emitLine(builder.fmtBr(labelName: loopHdr))
 emitLine("")
 emitLine(" \(loopHdr):")
 let curPtr = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: curPtr, type: "ptr", ptr: slot))
 let ch = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: ch, type: "i8", ptr: curPtr))
 let done = "%t\(nextTemp())"
 emitLine(" \(done) = icmp eq i8 \(ch), 0")
 emitLine(builder.fmtCondBr(cond: done, thenLabelName: loopEnd, elseLabelName: loopBdy))
 emitLine("")
 emitLine(" \(loopBdy):")
 let i32e = "%t\(nextTemp())"
 emitLine(" \(i32e) = sext i8 \(ch) to i32")
 let conv = "%t\(nextTemp())"
 emitLine(" \(conv) = call i32 @\(funcName)(i32 \(i32e))")
 let i8t = "%t\(nextTemp())"
 emitLine(" \(i8t) = trunc i32 \(conv) to i8")
 emitLine(builder.fmtStore(value: i8t, type: "i8", ptr: curPtr))
 let next = "%t\(nextTemp())"
 emitLine(builder.fmtGEPByteOffset(name: next, base: curPtr, offset: "1", offsetType: "i32"))
 emitLine(builder.fmtStore(value: next, type: "ptr", ptr: slot))
 emitLine(builder.fmtBr(labelName: loopHdr))
 emitLine("")
 emitLine(" \(loopEnd):")
 return IRValue(llvmType: "ptr", ssaName: copyBuf)
 }

 func generateStringSubstring(_ str: String, _ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count == 2 else { throw IRGenError.unsupportedExpression(kind:"substring requires 2 args", sl()) }
 let start = try generateExpression(arguments[0].expression)
 let len = try generateExpression(arguments[1].expression)
 let sz = "%t\(nextTemp())"
 emitLine(" \(sz) = sext i32 \(len.ssaName) to i64")
 let sz1 = "%t\(nextTemp())"
 emitLine(" \(sz1) = add i64 \(sz), 1")
 let buf = "%t\(nextTemp())"
 emitLine(" \(buf) = alloca i8, i64 \(sz1)") // VLA
 let srcOfs = "%t\(nextTemp())"
 emitLine(" \(srcOfs) = sext i32 \(start.ssaName) to i64")
 let src = "%t\(nextTemp())"
 emitLine(builder.fmtGEPByteOffset(name: src, base: str, offset: srcOfs, offsetType: "i64"))
 let cp = "%t\(nextTemp())"
 emitLine(" \(cp) = call ptr @memcpy(ptr \(buf), ptr \(src), i64 \(sz))")
 let nl = "%t\(nextTemp())"
 emitLine(builder.fmtGEPByteOffset(name: nl, base: buf, offset: sz, offsetType: "i64"))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: nl))
 return IRValue(llvmType: "ptr", ssaName: buf)
 }

 /// IR: s.split(",") → strtok 循环构建 "[a, b, c]"
 func generateStringSplit(_ str: String, _ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count == 1 else { throw IRGenError.unsupportedExpression(kind:"split requires 1 arg (delimiter)", sl()) }
 let delim = try generateExpression(arguments[0].expression)
 // 结果缓冲区
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[1024 x i8]"))
 let result = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: result, aggregate: "[1024 x i8]", base: buf, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: result))
 // 拷贝输入（strtok 会修改）
 let copy = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: copy, type: "[1024 x i8]"))
 let copyp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: copyp, aggregate: "[1024 x i8]", base: copy, indices: [0, 0]))
 let sl = "%t\(nextTemp())"
 emitLine(" \(sl) = call i64 @strlen(ptr \(str))")
 emitLine(" \("%t\(nextTemp())") = call ptr @memcpy(ptr \(copyp), ptr \(str), i64 \(sl))")
 let nl = "%t\(nextTemp())"
 emitLine(builder.fmtGEPByteOffset(name: nl, base: copyp, offset: sl, offsetType: "i64"))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: nl))
 // 首个 token
 let t1 = "%t\(nextTemp())"
 emitLine(" \(t1) = call ptr @strtok(ptr \(copyp), ptr \(delim.ssaName))")
 // 前置 "["
 let lp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: lp, aggregate: "[2 x i8]", base: "@.split_lbr", indices: [0, 0]))
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(lp))")
 // 可变指针 slot（避免 PHI）
 let slot = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: slot, type: "ptr"))
 emitLine(builder.fmtStore(value: t1, type: "ptr", ptr: slot))
 // 循环头
 let lid = nextLabel()
 let loopHdr = "split_hdr_\(lid)"
 let loopBdy = "split_bdy_\(lid)"
 let loopSep = "split_sep_\(lid)"
 let loopEnd = "split_end_\(lid)"
 emitLine(builder.fmtBr(labelName: loopHdr))
 emitLine("")
 emitLine(" \(loopHdr):")
 let cur = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: cur, type: "ptr", ptr: slot))
 let done = "%t\(nextTemp())"
 emitLine(" \(done) = icmp eq ptr \(cur), null")
 emitLine(builder.fmtCondBr(cond: done, thenLabelName: loopEnd, elseLabelName: loopBdy))
 emitLine("")
 emitLine(" \(loopBdy):")
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(cur))")
 let nxt = "%t\(nextTemp())"
 emitLine(" \(nxt) = call ptr @strtok(ptr null, ptr \(delim.ssaName))")
 emitLine(builder.fmtStore(value: nxt, type: "ptr", ptr: slot))
 let hasNxt = "%t\(nextTemp())"
 emitLine(" \(hasNxt) = icmp ne ptr \(nxt), null")
 emitLine(builder.fmtCondBr(cond: hasNxt, thenLabelName: loopSep, elseLabelName: loopHdr))
 emitLine("")
 emitLine(" \(loopSep):")
 let sp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: sp, aggregate: "[3 x i8]", base: "@.split_sep", indices: [0, 0]))
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(sp))")
 emitLine(builder.fmtBr(labelName: loopHdr))
 emitLine("")
 emitLine(" \(loopEnd):")
 let rp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: rp, aggregate: "[2 x i8]", base: "@.split_rbr", indices: [0, 0]))
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(rp))")
 return IRValue(llvmType: "ptr", ssaName: result)
 }

 /// IR: `["a","b"].join("-")` / 变量数组 `arr.join("-")` → 逐元素拼接（元素为字符串 ptr）+ 分隔符。
 ///
 /// - `[N x ptr]` 字面量数组：编译期已知长度，extractvalue + strcat（既有路径，golden IR 不变）。
 /// - `%bk_array*` 不透明句柄（变量绑定数组，Phase 1 #7）：经 `@bk_array_len`/`@bk_array_get`
 /// 按运行时长度循环（对齐 `generateStringifyArray` 的迭代约定），元素解箱为 ptr 后 strcat。
 func generateArrayJoin(_ arr: IRValue, _ arguments: [CallArgument]) throws -> IRValue {
 guard arguments.count == 1 else { throw IRGenError.unsupportedExpression(kind:"join requires 1 arg (separator)", sl()) }
 let sep = try generateExpression(arguments[0].expression)
 // 结果缓冲区
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[4096 x i8]"))
 let result = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: result, aggregate: "[4096 x i8]", base: buf, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: result))

 if arr.llvmType == "%bk_array*" {
 // 运行时句柄：@bk_array_len + @bk_array_get 循环（支持变量绑定/动态长度数组）。
 usesCollections = true
 let raw = "%t\(nextTemp())"
 emitLine(" \(raw) = bitcast %bk_array* \(arr.ssaName) to ptr")
 let len = "%t\(nextTemp())"
 emitLine(" \(len) = call i32 @bk_array_len(ptr \(raw))")
 let ivar = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: ivar, type: "i32"))
 emitLine(builder.fmtStore(value: "0", type: "i32", ptr: ivar))
 let label = nextLabel()
 let condL = "join_cond_\(label)", bodyL = "join_body_\(label)", sepL = "join_sep_\(label)", elemL = "join_elem_\(label)", endL = "join_end_\(label)"
 emitLine(builder.fmtBr(labelName: condL))
 emitLine("\(condL):")
 let iv = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: iv, type: "i32", ptr: ivar))
 let cmp = "%t\(nextTemp())"
 emitLine(" \(cmp) = icmp slt i32 \(iv), \(len)")
 emitLine(builder.fmtCondBr(cond: cmp, thenLabelName: bodyL, elseLabelName: endL))
 emitLine("\(bodyL):")
 let isFirst = "%t\(nextTemp())"
 emitLine(" \(isFirst) = icmp eq i32 \(iv), 0")
 emitLine(builder.fmtCondBr(cond: isFirst, thenLabelName: elemL, elseLabelName: sepL))
 emitLine("\(sepL):")
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(sep.ssaName))")
 emitLine(builder.fmtBr(labelName: elemL))
 emitLine("\(elemL):")
 let box = "%t\(nextTemp())"
 emitLine(" \(box) = call ptr @bk_array_get(ptr \(raw), i32 \(iv))")
 let ev = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: ev, type: "ptr", ptr: box))
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(ev))")
 let iv2 = "%t\(nextTemp())"
 emitLine(" \(iv2) = add i32 \(iv), 1")
 emitLine(builder.fmtStore(value: iv2, type: "i32", ptr: ivar))
 emitLine(builder.fmtBr(labelName: condL))
 emitLine("\(endL):")
 return IRValue(llvmType: "ptr", ssaName: result)
 }

 // 编译期定长字面量数组 [N x ptr]：extractvalue + strcat（既有路径）。
 guard let lb = arr.llvmType.firstIndex(of: "["),
 let x = arr.llvmType.firstIndex(of: "x"),
 let rb = arr.llvmType.firstIndex(of: "]"),
 let count = Int(arr.llvmType[arr.llvmType.index(after: lb)..<x].trimmingCharacters(in: .whitespaces)) else {
 throw IRGenError.unsupportedExpression(kind:"join expects [N x ptr] array, got \(arr.llvmType)", sl())
 }
 var idx = 0
 while idx < count {
 let ev = "%t\(nextTemp())"
 emitLine(" \(ev) = extractvalue \(arr.llvmType) \(arr.ssaName), \(idx)")
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(ev))")
 if idx < count - 1 {
 let sp = "%t\(nextTemp())"
 emitLine(" \(sp) = call ptr @strcat(ptr \(result), ptr \(sep.ssaName))")
 _ = sp // unused return
 }
 idx += 1
 }
 return IRValue(llvmType: "ptr", ssaName: result)
 }

 // 聚合类型（枚举/结构/对象，IR 命名为 % 前缀类型）在 LLVM 后端的打印已实现：
 // generatePrintCall / generateMultiArgPrint 在遇 % 前缀类型时经 `generateStringify` 递归格式化
 // （对齐解释器 `stringify` 展示语义，见 G-IR-enum-print T2）。集合/元组类聚合仍走 scalar 路径。

 /// `len` 内置的 IR 路径。
 /// - 数组 `[N x T]` / 元组 `{T1, T2}`：长度已编码在类型中，直接折叠为**编译期常量**，不产生运行时调用。
 /// - 字符串 `ptr`：运行时 `strlen`（C 语义，返回**字节数**），再 `trunc` 到 Pini 的 i32。
 ///
 /// 已知语义缺口（不掩盖）：解释器的 `len(string)` 返回 Swift `String.count`（**字符数**），
 /// ASCII 下与 `strlen` 一致，多字节字符（如中文）下不一致。待字符串运行时表示统一后收敛。
 func generateLenCall(arguments: [CallArgument]) throws -> IRValue {
 let loc = SourceLocation(line: 0, column: 0, fileName: "")
 guard arguments.count == 1, let arg = arguments.first else {
 throw IRGenError.unsupportedExpression(kind:"len 需要恰好 1 个参数，实际 \(arguments.count) 个", loc)
 }

 let val = try generateExpression(arg.expression)

 // 数组句柄（%bk_array*）：运行时 @bk_array_len（ADR-008 / #46-D）。
 // 与字符串 `ptr` 分支严格区分——前者走 shim，后者走 strlen 字节计数。
 if val.llvmType == "%bk_array*" {
 usesCollections = true
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast %bk_array* \(val.ssaName) to ptr")
 let n = builder.freshTemp()
 emitLine(" \(n) = call i32 @bk_array_len(ptr \(raw))")
 return IRValue(llvmType: "i32", ssaName: n)
 }

 // #46-D D2：字典 / 集合句柄（%bk_dict* / %bk_set*）走运行时 shim @bk_dict_len / @bk_set_len。
 if val.llvmType == "%bk_dict*" {
 usesCollections = true
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast %bk_dict* \(val.ssaName) to ptr")
 let n = builder.freshTemp()
 emitLine(" \(n) = call i32 @bk_dict_len(ptr \(raw))")
 return IRValue(llvmType: "i32", ssaName: n)
 }
 if val.llvmType == "%bk_set*" {
 usesCollections = true
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast %bk_set* \(val.ssaName) to ptr")
 let n = builder.freshTemp()
 emitLine(" \(n) = call i32 @bk_set_len(ptr \(raw))")
 return IRValue(llvmType: "i32", ssaName: n)
 }

 // 数组：定长长度是编译期常量
 if let n = arrayElementCount(of: val.llvmType) {
 return IRValue(llvmType: "i32", ssaName: "\(n)")
 }

 // 元组：顶层字段数是编译期常量
 if let n = structFieldCount(of: val.llvmType) {
 return IRValue(llvmType: "i32", ssaName: "\(n)")
 }

 // 字符串：运行时统计「字符数」，与解释器 String.count 对齐（Bug B）。
 // 解释器用 grapheme 簇；LLVM 侧按「非 UTF-8 续行字节(0x80-0xBF)」计数得 Unicode 标量数，
 // CJK/常见文本下标量==字形簇（你好世界→4），与解释器一致；含 ZWJ/肤色修饰的 emoji 属已知边界。
 if val.llvmType == "ptr" {
 let lenSlot = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: lenSlot, type: "i32"))
 emitLine(builder.fmtStore(value: "0", type: "i32", ptr: lenSlot))
 let idxSlot = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: idxSlot, type: "i64"))
 emitLine(builder.fmtStore(value: "0", type: "i64", ptr: idxSlot))
 let loopLbl = nextLabel()
 let loop = "len_loop_\(loopLbl)"
 let done = "len_done_\(loopLbl)"
 let body = "len_body_\(loopLbl)"
 let count = "len_count_\(loopLbl)"
 let inc = "len_inc_\(loopLbl)"
 emitLine(builder.fmtBr(labelName: loop))
 emitLine("\(loop):")
 let idx = builder.freshTemp()
 emitLine(builder.fmtLoad(name: idx, type: "i64", ptr: idxSlot))
 let p = builder.freshTemp()
 emitLine(builder.fmtGEPByteOffset(name: p, base: val.ssaName, offset: idx, offsetType: "i64"))
 let c = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: c, type: "i8", ptr: p))
 let isEnd = "%t\(nextTemp())"
 emitLine(" \(isEnd) = icmp eq i8 \(c), 0")
 emitLine(builder.fmtCondBr(cond: isEnd, thenLabelName: done, elseLabelName: body))
 emitLine("\(body):")
 let band = "%t\(nextTemp())"
 emitLine(" \(band) = and i8 \(c), 192")
 let isCont = "%t\(nextTemp())"
 emitLine(" \(isCont) = icmp eq i8 \(band), 128")
 emitLine(builder.fmtCondBr(cond: isCont, thenLabelName: inc, elseLabelName: count))
 emitLine("\(count):")
 let cur = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: cur, type: "i32", ptr: lenSlot))
 let cur1 = "%t\(nextTemp())"
 emitLine(" \(cur1) = add i32 \(cur), 1")
 emitLine(builder.fmtStore(value: cur1, type: "i32", ptr: lenSlot))
 emitLine(builder.fmtBr(labelName: inc))
 emitLine("\(inc):")
 let idx1 = "%t\(nextTemp())"
 emitLine(" \(idx1) = add i64 \(idx), 1")
 emitLine(builder.fmtStore(value: idx1, type: "i64", ptr: idxSlot))
 emitLine(builder.fmtBr(labelName: loop))
 emitLine("\(done):")
 let result = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: result, type: "i32", ptr: lenSlot))
 return IRValue(llvmType: "i32", ssaName: result)
 }

 throw IRGenError.unsupportedExpression(kind:"len 不支持的 IR 类型：\(val.llvmType)", loc)
 }

 /// 解析定长数组类型 `[N x T]` 的元素个数 N；非数组类型返回 nil。
 func arrayElementCount(of llvmType: String) -> Int? {
 guard llvmType.hasPrefix("["), llvmType.hasSuffix("]") else { return nil }
 let inner = llvmType.dropFirst().dropLast()
 guard let xRange = inner.range(of: " x ") else { return nil }
 return Int(inner[inner.startIndex..<xRange.lowerBound].trimmingCharacters(in: .whitespaces))
 }

 /// 解析 struct 类型 `{ T1, T2 }` 的**顶层**字段数；非 struct 返回 nil。
 /// 按括号深度计逗号，确保嵌套 `{ i32, { i32, i1 } }` 得 2 而非 3。
 func structFieldCount(of llvmType: String) -> Int? {
 guard llvmType.hasPrefix("{"), llvmType.hasSuffix("}") else { return nil }
 let inner = llvmType.dropFirst().dropLast()
 if inner.trimmingCharacters(in: .whitespaces).isEmpty { return 0 }
 var depth = 0
 var count = 1
 for ch in inner {
 switch ch {
 case "{", "[", "(": depth += 1
 case "}", "]", ")": depth -= 1
 case "," where depth == 0: count += 1
 default: break
 }
 }
 return count
 }
}
