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
void bk_str_release(char *text);

#endif
"""#
}
