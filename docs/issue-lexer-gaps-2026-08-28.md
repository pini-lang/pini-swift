# Issue: lexer 实现的语言能力缺口 — 宿主完善工单

- **状态**：Open
- **提出视角**：自举项目（`pini/` 编译器 lexer 设计——吃狗粮实证：探针验证 + 宿主源码核查）
- **关联交付**：`pini/` 自举编译器（ADR-018 G1/G2）、`pini/src/common/token.pini`（已落地）
- **范围**：lexer 实现所需的 Pini 语言能力缺口，指导宿主后续完善工作。不拆分子工单，统一在本 issue 跟踪。
- **证据**：所有缺口均经宿主 CLI 探针实证（见附录复现命令）或宿主源码核查。

---

## 一、阻塞缺口（lexer 命门，优先立项）

> 这三项是 lexer 能否写出的前提：IDENT 判定 + 结果集合构建。不依赖安全模型（第二节），可先行。

| # | 缺口 | lexer 依据 | 实证 | 建议 |
|---|---|---|---|---|
| P1-A | **字符谓词 `is_letter`**（UCD \p{L}） | IDENT 首字符判定（EBNF `\p{L}`）——**不可绕过**（Unicode 字母表手写不现实） | `is_letter(c)` 报 E3-002 undefined function；字符串大小比较 `>=` 报 E5-003 type mismatch | 宿主内建（Swift `Character.isLetter`），`String -> Bool`；LLVM 端受 T14 约束 |
| P1-B | **数组追加 `append`** | lexer 产出 `[token]` 输出、收集 `[diag]`——无构建即无法产出结果 | `a.append(1)` 报 E5-001 undefined variable；`a + [x]` 报 E5-003 type mismatch；数组仅有字面量/下标/len/join | 宿主内建 + spec 登记（集合构建原语） |
| P1-C | **数组栈操作**（pop/remove_last/peek） | IndentTracker 缩进栈（push/pop，宿主 `IndentTracker.swift` 同构） | 同 P1-B（无任何数组可变方法） | 宿主内建（`pop`/`last`/`remove_last` 之一族）+ spec 登记 |

## 二、语义批次（集合操作安全模型，规格 v0 已讨论定稿）

> 安全模型定义：**安全通道（索引/切片）越界返回可空（nil），调用者显式解包；不安全通道（单元素直接访问）搁置，未来经 trait 为集合默认派发。** 下标 `a[i]` 机制 = 零拷贝全切片视图 → 负索引映射（i<0 → len+i）→ 边界检查 → 界内返回 T / 越界返回 nil。

| # | 缺口 | 现状 | 建议 | 类型 |
|---|---|---|---|---|
| P2-A | **负索引**（下标 + 切片尾部计数） | `a[-1]` 崩溃（E5-006） | 实现 i<0 → len+i（-k=len-k，-len=首元素） | 新特性 |
| P2-B | **切片语法** `a[i:j]`/`a[i:]`/`a[:j]`/`a[:]` | 无（仅字符串 substring） | Python 风（半开区间），步长 `a[i:j:k]` 暂缓 | 新特性 |
| P2-C | **越界返回可空（nil）** | 数组/字符串下标越界崩溃（E5-006）；**字典缺失键已返回 null**（`testDictionarySubscriptMissingKeyReturnsNull`）——不一致实证 | 统一安全通道越界 → nil | 行为变更（破坏性） |
| P2-D | `substring` 负索引语义（夹 0 → 尾部计数） | 负索引夹紧到 0（`testSubstringNegativeIndexClamped`：`substring(-1,3)=="hel"`） | 改尾部计数（Python 一致） | 行为变更（破坏性，需迁移） |
| P2-E | 可空类型支持（`a[i]` 返回 T?） | nil 存在，Optional 部分支持 | 类型系统扩展（下标/切片返回可空） | 类型系统 |
| P2-F | **unsafe 单元素直接访问**（trait 派发） | — | **搁置**（backlog：底层内建特征默认为集合派发不安全访问） | 搁置 |

## 三、后续缺口（不阻塞 lexer 启动）

| # | 缺口 | 建议 |
|---|---|---|
| P3-A | `is_digit` / `is_space` 字符谓词 | 宿主内建（isDigit/isWhitespace），替代不可行的字符串大小比较 |
| P3-B | 字符串下标索引单位（码点 vs 字素簇） | spec 登记（`s[i]` 取"单字符"的单位未定义） |
| P3-C | char 类型 / 字符字面量 `'a'` | 暂缓（单字符字符串承载可绕开） |
| P3-D | 数组拼接/复制 | 后续（切片组合） |
| P3-E | 字典/集合可变操作（set/remove） | 后续（符号表需求） |

## 四、spec 治理对齐

| # | 缺口 | 说明 |
|---|---|---|
| P4-A | 宿主 lexer 与 EBNF 不一致（pass vs test） | 宿主 Keyword 有 `pass` 无 `test`；EBNF KEYWORD 有 `test` 无 `pass`——宿主向 EBNF 对齐（tokens 差分契约例外项） |
| P4-B | EBNF `\p{L}` 定义 vs 运行时无字符 API | 规范与实现脱节（P1-A 根因）——spec 登记 |
| P4-C | 下标越界行为未在 spec 定义 | 崩溃 vs 可空（P2-C 需 spec G 新编号登记） |
| P4-D | 字典 null vs 数组崩溃的不一致 | 安全模型统一（随 P2-C） |

## 五、验收口径（Definition of Done）

- [ ] P1-A 落地：`is_letter` 内建可用（探针 + 测试），IDENT 判定成立
- [ ] P1-B/C 落地：数组 `append` + 栈操作可用，lexer 可产出 `[token]`/`[diag]`/缩进栈
- [ ] 阻塞项落地后 `pini/` lexer 可写出（阶段差分门禁：tokens 输出对齐宿主，P2 契约）
- [ ] P2 安全模型 spec 登记（G 新编号）：负索引/切片/越界可空/substring 语义变更 + 迁移说明
- [ ] P2-F（unsafe 通道）登记 roadmap backlog（搁置）
- [ ] P4-A 宿主 lexer 向 EBNF 对齐（pass/test）

---

## 附录：探针复现命令

```bash
# P1-A 字符谓词缺失
echo 'main|func() -> ()\n    var c = "h"\n    var d = is_letter(c)\n    print(d)\n    return' | pini check -   # E3-002 undefined function is_letter

# P1-B/C 数组构建缺失
echo 'main|func() -> ()\n    var a = []\n    a.append(1)\n    print(a)\n    return' | pini run -    # E5-001 undefined variable append

# P2-A 负索引缺失
echo 'main|func() -> ()\n    var a = [1,2,3]\n    print(a[-1])\n    return' | pini run -    # E5-006 越界崩溃

# P2-C 越界崩溃（vs 字典 null）
echo 'main|func() -> ()\n    var a = [1,2,3]\n    print(a[5])\n    return' | pini run -    # E5-006 崩溃
echo 'main|func() -> ()\n    var d = {"k": 1}\n    print(d["missing"])\n    return' | pini run -   # null（先例）

# P2-D substring 负索引夹紧（非尾部计数）
echo 'main|func() -> ()\n    print("hello".substring(-1, 3))\n    return' | pini run -   # "hel"（夹 0）
```
