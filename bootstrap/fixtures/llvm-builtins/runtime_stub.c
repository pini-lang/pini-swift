/* 验收桩：数组族的最小 C 实现，够跑通样例；真实运行时另经 runtime-api 门禁。
   元素按宽度搬字节，长度按个数记；句柄就是本文件里的结构体指针。 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int32_t count;
    int32_t cap;
    int32_t *items;
} stub_array;

void bk_print_lock(void) {}
void bk_print_unlock(void) {}

void *bk_array_create(int32_t len) {
    stub_array *a = calloc(1, sizeof *a);
    a->cap = len > 0 ? len : 4;
    a->items = calloc((size_t)a->cap, sizeof(int32_t));
    a->count = len;
    return a;
}

int32_t bk_array_len(void *handle) {
    if (handle == NULL) {
        return 0;
    }
    return ((stub_array *)handle)->count;
}

void *bk_array_append(void *handle, const void *src, int32_t width, int32_t tag) {
    (void)tag;
    stub_array *a = handle;
    if (a->count == a->cap) {
        a->cap = a->cap > 0 ? a->cap * 2 : 4;
        a->items = realloc(a->items, (size_t)a->cap * sizeof(int32_t));
    }
    memcpy(&a->items[a->count], src, (size_t)width);
    a->count += 1;
    return a;
}

/* 桩只按字节计字符数：样例是纯 ASCII，与运行时的字素簇口径在此同值。 */
int32_t bk_string_count(const char *text) {
    return text == NULL ? 0 : (int32_t)strlen(text);
}
