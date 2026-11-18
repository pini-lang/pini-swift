/* 验收桩：只提供发射产物引用的几个 C 符号，不替代运行时实现。
   打印与陷阱行为够跑通样例即可；真实运行时另经 runtime-api 门禁。 */
#include <stdio.h>

void bk_print_lock(void) {}
void bk_print_unlock(void) {}
void bk_panic(const char *message) { fprintf(stderr, "panic: %s\n", message); }
void bk_str_release(void *value) { (void)value; }
char *bk_double_to_string(double value) {
    static char buffer[64];
    snprintf(buffer, sizeof buffer, "%g", value);
    return buffer;
}
