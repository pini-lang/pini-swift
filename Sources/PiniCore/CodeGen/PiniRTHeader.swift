import Foundation

/// 生成 C 代码所链接的运行时段头文件。随编译器分发、由 `pini build --c-backend` 落盘,
/// 单一出处即本件 —— 头与实际 ABI 的偏差只能在这一处产生，也只能在这一处被看见。
public enum PiniRTHeader {

    /// 落盘文件名。生成物以 `#include "pini_rt.h"` 引用它，两者必须同名。
    public static let fileName = "pini_rt.h"

    /// 头文件正文。`_Static_assert` 是布局判据：C 侧算出的字节数与发射层不一致时，
    /// 产物在编译期就红，而不是在运行期读到错位的字段。
    public static let source = #"""
// pini_rt.h —— 生成 C 代码所链接的运行时段契约，随产物落盘。
#ifndef PINI_RT_H
#define PINI_RT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
// 生成物直接调这几个 libc / libm 名字（与 LLVM 头里的裸名 declare 一一对应）。
#include <stdlib.h>
#include <string.h>
#include <math.h>

// 名义箱的对象头：四格，与发射层的 headerSlotCount 同源。
// 12–15 是 weak_table 的对齐填充，故 64 位下 sizeof 为 24。
typedef struct PiniHeader {
    _Atomic uint32_t strong;
    _Atomic uint32_t weak;
    uint32_t type_id;
    struct PiniWeakTable *weak_table;
} PiniHeader;

_Static_assert(sizeof(PiniHeader) == 2 * sizeof(void *) + 8, "PiniHeader layout drifted from the emitter");
// 发射层按指针 8 字节推字段偏移；指针不是 8 字节时那些偏移量全错，故在此拦下，
// 而不是让产物在 32 位目标上读到错位字段。
_Static_assert(sizeof(void *) == 8, "the C backend assumes a 64-bit target");

void *bk_nominal_alloc(int64_t size, int32_t type_id);
void bk_nominal_retain(void *box);
int32_t bk_nominal_release(void *box);

// 不返回：调用点之后的语句不可达，故生成物无需补 return。
_Noreturn void bk_panic(const char *message);
void bk_set_program_base(const char *base);
char *bk_double_to_string(double value);
void bk_str_retain(char *text);
void bk_str_release(char *text);
char *bk_str_dup(const char *source);

// 容器句柄：三个族共用同一套 share 记账，句柄在 C 侧一律是不透明 `void *`。
// `*_set` / `*_add` 收的是「值的地址 + 字节宽 + 元素 tag」，返回写回的句柄（COW 可能换箱）。
void bk_handle_retain(void *handle);

void *bk_array_create(int32_t len);
int32_t bk_array_len(void *array);
void *bk_array_get(void *array, int32_t index);
void *bk_array_set(void *array, int32_t index, void *source, int32_t elemBytes, int32_t elemTag);
void *bk_array_append(void *array, void *source, int32_t elemBytes, int32_t elemTag);
void bk_array_destroy(void *array);

void *bk_dict_create(void);
int32_t bk_dict_len(void *dict);
void *bk_dict_key_at(void *dict, int32_t index);
void *bk_dict_val_at(void *dict, int32_t index);
void *bk_dict_get(void *dict, void *key, int32_t keyBytes, int32_t keyTag);
void *bk_dict_set(
    void *dict, void *key, int32_t keyBytes, int32_t keyTag,
    void *value, int32_t valueBytes, int32_t valueTag);
void bk_dict_destroy(void *dict);

void *bk_set_create(void);
int32_t bk_set_len(void *set);
void *bk_set_at(void *set, int32_t index);
void *bk_set_add(void *set, void *element, int32_t elemBytes, int32_t elemTag);
void bk_set_destroy(void *set);

// 字符串的长度按字素簇计（与解释器的 `text.count` 同一定义），不在 C 侧按字节数。
int32_t bk_string_count(const char *text);
// 取第 i 个字素簇（负值尾计数，越界即陷阱）；交出的是新分配串，与其余抬串同族。
char *bk_string_char_at(const char *text, int32_t index);

// 抬串一族：返回值都是带计数头的新分配串（`bk_str_alloc` 那块），释放走 `bk_str_release`。
// 语义（字素簇 · Unicode 大小写 · 负值尾计数）一律在运行时段，C 侧只搬运。
char *bk_str_alloc(int64_t byte_count);
char *bk_string_upper(const char *text);
char *bk_string_lower(const char *text);
int32_t bk_string_contains(const char *haystack, const char *needle);
char *bk_substring(const char *text, int32_t start, int32_t end);
// 切出的数组与 `bk_array_create` 同族：元素是 8 字节 C 串槽（tag 3），句柄走 `bk_array_destroy`。
void *bk_string_split(const char *text, const char *delim);
// 切片：两个 has* 是开界标志（不是下标哨兵 —— 哨兵会与真实 -1 撞车）；负值尾计数与夹取在运行时段。
char *bk_string_slice(const char *text, int32_t hasStart, int32_t start, int32_t hasEnd, int32_t end);

// LazyRef：不透明句柄，首访同步求值并缓存（内部锁保证恰一次），复制即共享同一盒。
// wrapper 是发射层合成的类型特化装箱函数，ABI `void *(void *code, void *env, void *out)`。
void *bk_lazyref_create(void *wrapper, void *code, void *env, int32_t elemBytes, int32_t elemTag);
void *bk_lazyref_value(void *handle);

// 整文件 IO：读失败返回 NULL（发射侧的陷阱判据）；写与追加不返回值，失败即 `bk_panic`。
char *bk_read_file(const char *path);
void bk_write_file(const char *path, const char *content);
void bk_append_file(const char *path, const char *content);

#endif
"""#
}
