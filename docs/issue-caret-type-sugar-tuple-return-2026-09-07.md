# Issue：`-> (^T,)` —— 函数返回 Result 的标注写法 spec 未明说（`^T` 类型糖嵌元组）

- 状态：**Open（2026-09-07 try-else 迁移 M2 批实测发现立案，M5 登记）**
- 来源：`examples/try.pini` 迁移实测（ADR-032 M2/M3）；`docs/spec/adr/adr-032-try-else-migration.md` M2 落地记录预告本工单
- 关联：spec §2.4.4『try-else 错误传播』节；§A 返回位文法（返回位只接受元组）

## 缺陷描述

Pini 返回位只接受元组（`-> (T,)` 形态）。函数要返回 `Result` 时，唯一可行写法是把
`^T` 类型糖（≡ `Result<T>`）作为元组字段：

```pini
读取文件|func(路径: String,) -> (^String,):
    return err("模拟错误")
```

这一**惯用法是迁移实测中唯一跑通的 Result 返回标注**，但 spec §2.4.4 只定义了
try-else 的操作数静态要求（`Result<T, E>`）与 `^e` 右值脱糖，**未明说**：

1. `^T` 糖嵌在返回元组字段位是「函数返回 Result 的官方写法」；
2. 裸 `-> Result(String,)` 是否合法（实测带形参的裸声明不带返回标注无法消歧，
   显式 `-> Result(String,)` 亦被返回位元组文法拒绝——`读取文件|func(路径: String,)
   -> Result(String,)` 报错，实测记录见 examples/try.pini 迁移过程）；
3. 调用方拿到的字段类型如何呈现（`^String` 展开为 `Result<String>` 的表述位置）。

## 请求

1. spec §2.4.4（或 §A 类型标注节）明文化：函数返回 Result = `^T` 糖嵌元组字段
   （`-> (^T,)`），并给出一个规范样例；
2. 明确 `-> Result(T,)` 直写形态的合法性裁决（允许 / 拒绝并说明文法依据）；
3. 如允许直写形态，属语言面增强，走 §1.3 提议流程另行立项。

## DoD

- spec 载明 Result 返回标注的权威写法与样例；
- GrammarConsistencyTests 或类型层测试覆盖该写法（若文法有改动）；
- examples/try.pini 与 spec 样例一致。
