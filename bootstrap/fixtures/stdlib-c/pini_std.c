// Pini 标准库的 C 内核：18 个字符串成员的外部实现，供装配对照测试顶替同名成员。
// 口径按码位而非字素簇；组合序列与 ZWJ 表情与 Pini 侧分叉，由对照脚本单独读数。
// 返回的串一律 malloc 分配、NUL 结尾，调用方经 ps_free 归还。

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t *cps;
    size_t len;
} ps_text;

// 解一个码位，写入 used；非法起始字节按 U+FFFD 前进一个字节，长度口径保持稳定。
static uint32_t ps_decode_one(const unsigned char *p, size_t *used) {
    unsigned char c = p[0];
    if (c < 0x80) {
        *used = 1;
        return (uint32_t)c;
    }
    if ((c & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80) {
        *used = 2;
        return ((uint32_t)(c & 0x1F) << 6) | (uint32_t)(p[1] & 0x3F);
    }
    if ((c & 0xF0) == 0xE0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
        *used = 3;
        return ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(p[1] & 0x3F) << 6) |
               (uint32_t)(p[2] & 0x3F);
    }
    if ((c & 0xF8) == 0xF0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 &&
        (p[3] & 0xC0) == 0x80) {
        *used = 4;
        return ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(p[1] & 0x3F) << 12) |
               ((uint32_t)(p[2] & 0x3F) << 6) | (uint32_t)(p[3] & 0x3F);
    }
    *used = 1;
    return 0xFFFD;
}

static ps_text ps_from_cstr(const char *s) {
    ps_text out = {NULL, 0};
    size_t n = strlen(s);
    uint32_t *cps = (uint32_t *)malloc((n + 1) * sizeof(uint32_t));
    if (cps == NULL) {
        return out;
    }
    size_t at = 0;
    size_t i = 0;
    while (i < n) {
        size_t used = 0;
        cps[at++] = ps_decode_one((const unsigned char *)s + i, &used);
        i += used;
    }
    out.cps = cps;
    out.len = at;
    return out;
}

static size_t ps_encode_one(uint32_t cp, char *out) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

// 把码位序列编成新串；空序列也得空串，调用方不必特判。
static char *ps_to_cstr(const uint32_t *cps, size_t len) {
    size_t cap = len * 4 + 1;
    char *out = (char *)malloc(cap);
    if (out == NULL) {
        return NULL;
    }
    size_t at = 0;
    for (size_t i = 0; i < len; i++) {
        at += ps_encode_one(cps[i], out + at);
    }
    out[at] = '\0';
    return out;
}

// 判定 a[at..at+blen) 与 b 逐码位相等；越界即假。
static int ps_match(const uint32_t *a, size_t alen, size_t at, const uint32_t *b, size_t blen) {
    if (at + blen > alen) {
        return 0;
    }
    for (size_t i = 0; i < blen; i++) {
        if (a[at + i] != b[i]) {
            return 0;
        }
    }
    return 1;
}

static char *ps_copy(const ps_text *text, size_t from, size_t to) {
    return ps_to_cstr(text->cps + from, to - from);
}

char *ps_trim(const char *s) {
    ps_text text = ps_from_cstr(s);
    size_t from = 0;
    size_t to = text.len;
    while (from < to && text.cps[from] == 0x20) {
        from++;
    }
    while (to > from && text.cps[to - 1] == 0x20) {
        to--;
    }
    char *out = ps_copy(&text, from, to);
    free(text.cps);
    return out;
}

int32_t ps_starts_with(const char *s, const char *prefix) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(prefix);
    int32_t hit = (b.len <= a.len) && ps_match(a.cps, a.len, 0, b.cps, b.len);
    free(a.cps);
    free(b.cps);
    return hit;
}

int32_t ps_ends_with(const char *s, const char *suffix) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(suffix);
    int32_t hit = (b.len <= a.len) && ps_match(a.cps, a.len, a.len - b.len, b.cps, b.len);
    free(a.cps);
    free(b.cps);
    return hit;
}

// 非重叠替换：命中后跳过整段模板；空模板原样返回，不插不删。
char *ps_replace(const char *s, const char *old_text, const char *replacement) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(old_text);
    ps_text c = ps_from_cstr(replacement);
    if (b.len == 0) {
        char *out = ps_copy(&a, 0, a.len);
        free(a.cps);
        free(b.cps);
        free(c.cps);
        return out;
    }
    size_t cap = (a.len + 1) * (c.len + 1) * 4 + 1;
    uint32_t *buf = (uint32_t *)malloc(cap * sizeof(uint32_t));
    if (buf == NULL) {
        free(a.cps);
        free(b.cps);
        free(c.cps);
        return NULL;
    }
    size_t at = 0;
    size_t i = 0;
    while (i < a.len) {
        if (ps_match(a.cps, a.len, i, b.cps, b.len)) {
            for (size_t k = 0; k < c.len; k++) {
                buf[at++] = c.cps[k];
            }
            i += b.len;
        } else {
            buf[at++] = a.cps[i];
            i++;
        }
    }
    char *out = ps_to_cstr(buf, at);
    free(buf);
    free(a.cps);
    free(b.cps);
    free(c.cps);
    return out;
}

// 次数非正得空串；次数按入参消费，不夹上限。
char *ps_repeat(const char *s, int32_t times) {
    ps_text a = ps_from_cstr(s);
    if (times <= 0) {
        char *out = ps_to_cstr(NULL, 0);
        free(a.cps);
        return out;
    }
    size_t total = a.len * (size_t)times;
    uint32_t *buf = (uint32_t *)malloc((total + 1) * sizeof(uint32_t));
    if (buf == NULL) {
        free(a.cps);
        return NULL;
    }
    for (size_t k = 0; k < (size_t)times; k++) {
        memcpy(buf + k * a.len, a.cps, a.len * sizeof(uint32_t));
    }
    char *out = ps_to_cstr(buf, total);
    free(buf);
    free(a.cps);
    return out;
}

// 填充串重复到够宽再按码位截断；空填充或已够宽原样返回。
static uint32_t *ps_fill(const ps_text *fill, size_t need, size_t *out_len) {
    if (need == 0 || fill->len == 0) {
        *out_len = 0;
        return (uint32_t *)malloc(sizeof(uint32_t));
    }
    uint32_t *buf = (uint32_t *)malloc(need * sizeof(uint32_t));
    if (buf == NULL) {
        *out_len = 0;
        return NULL;
    }
    for (size_t i = 0; i < need; i++) {
        buf[i] = fill->cps[i % fill->len];
    }
    *out_len = need;
    return buf;
}

static char *ps_pad(const char *s, int32_t width, const char *fill_text, int left) {
    ps_text a = ps_from_cstr(s);
    ps_text f = ps_from_cstr(fill_text);
    if (width <= 0 || f.len == 0 || a.len >= (size_t)width) {
        char *out = ps_copy(&a, 0, a.len);
        free(a.cps);
        free(f.cps);
        return out;
    }
    size_t need = (size_t)width - a.len;
    size_t pad_len = 0;
    uint32_t *pad = ps_fill(&f, need, &pad_len);
    uint32_t *buf = (uint32_t *)malloc((pad_len + a.len + 1) * sizeof(uint32_t));
    if (pad == NULL || buf == NULL) {
        free(pad);
        free(buf);
        free(a.cps);
        free(f.cps);
        return NULL;
    }
    size_t at = 0;
    if (left) {
        memcpy(buf, pad, pad_len * sizeof(uint32_t));
        at = pad_len;
    }
    memcpy(buf + at, a.cps, a.len * sizeof(uint32_t));
    at += a.len;
    if (!left) {
        memcpy(buf + at, pad, pad_len * sizeof(uint32_t));
        at += pad_len;
    }
    char *out = ps_to_cstr(buf, at);
    free(pad);
    free(buf);
    free(a.cps);
    free(f.cps);
    return out;
}

char *ps_pad_left(const char *s, int32_t width, const char *fill) {
    return ps_pad(s, width, fill, 1);
}

char *ps_pad_right(const char *s, int32_t width, const char *fill) {
    return ps_pad(s, width, fill, 0);
}

// 末次出现：答码位下标；空模板答长度，缺席答 -1。
int32_t ps_last_index_of(const char *s, const char *needle) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(needle);
    int32_t found = -1;
    if (b.len == 0) {
        found = (int32_t)a.len;
    } else if (b.len <= a.len) {
        size_t i = a.len - b.len;
        for (;;) {
            if (ps_match(a.cps, a.len, i, b.cps, b.len)) {
                found = (int32_t)i;
                break;
            }
            if (i == 0) {
                break;
            }
            i--;
        }
    }
    free(a.cps);
    free(b.cps);
    return found;
}

int32_t ps_is_empty(const char *s) {
    ps_text a = ps_from_cstr(s);
    int32_t empty = a.len == 0;
    free(a.cps);
    return empty;
}

// 非重叠计数；空模板答零，与 replace 的空模板口径一致。
int32_t ps_count(const char *s, const char *sub) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(sub);
    int32_t total = 0;
    if (b.len != 0) {
        size_t i = 0;
        while (i + b.len <= a.len) {
            if (ps_match(a.cps, a.len, i, b.cps, b.len)) {
                total++;
                i += b.len;
            } else {
                i++;
            }
        }
    }
    free(a.cps);
    free(b.cps);
    return total;
}

char *ps_strip_prefix(const char *s, const char *prefix) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(prefix);
    size_t from = (b.len <= a.len && ps_match(a.cps, a.len, 0, b.cps, b.len)) ? b.len : 0;
    char *out = ps_copy(&a, from, a.len);
    free(a.cps);
    free(b.cps);
    return out;
}

char *ps_strip_suffix(const char *s, const char *suffix) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(suffix);
    size_t to = a.len;
    if (b.len <= a.len && ps_match(a.cps, a.len, a.len - b.len, b.cps, b.len)) {
        to = a.len - b.len;
    }
    char *out = ps_copy(&a, 0, to);
    free(a.cps);
    free(b.cps);
    return out;
}

// 已带前缀原样返回，否则拼在前面；空前缀恒判已带。
char *ps_ensure_prefix(const char *s, const char *prefix) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(prefix);
    size_t at = 0;
    uint32_t *buf = (uint32_t *)malloc((a.len + b.len + 1) * sizeof(uint32_t));
    if (buf == NULL) {
        free(a.cps);
        free(b.cps);
        return NULL;
    }
    int has = (b.len <= a.len) && ps_match(a.cps, a.len, 0, b.cps, b.len);
    if (!has) {
        memcpy(buf, b.cps, b.len * sizeof(uint32_t));
        at = b.len;
    }
    memcpy(buf + at, a.cps, a.len * sizeof(uint32_t));
    char *out = ps_to_cstr(buf, at + a.len);
    free(buf);
    free(a.cps);
    free(b.cps);
    return out;
}

// 已带后缀原样返回，否则拼在后面；空后缀恒判已带。
char *ps_ensure_suffix(const char *s, const char *suffix) {
    ps_text a = ps_from_cstr(s);
    ps_text b = ps_from_cstr(suffix);
    uint32_t *buf = (uint32_t *)malloc((a.len + b.len + 1) * sizeof(uint32_t));
    if (buf == NULL) {
        free(a.cps);
        free(b.cps);
        return NULL;
    }
    memcpy(buf, a.cps, a.len * sizeof(uint32_t));
    int has = (b.len <= a.len) && ps_match(a.cps, a.len, a.len - b.len, b.cps, b.len);
    if (!has) {
        memcpy(buf + a.len, b.cps, b.len * sizeof(uint32_t));
    }
    char *out = ps_to_cstr(buf, has ? a.len : a.len + b.len);
    free(buf);
    free(a.cps);
    free(b.cps);
    return out;
}

// 按码位倒排；组合序列会被拆开，字素口径的差异在此显形。
char *ps_reversed(const char *s) {
    ps_text a = ps_from_cstr(s);
    uint32_t *buf = (uint32_t *)malloc((a.len + 1) * sizeof(uint32_t));
    if (buf == NULL) {
        free(a.cps);
        return NULL;
    }
    for (size_t i = 0; i < a.len; i++) {
        buf[i] = a.cps[a.len - 1 - i];
    }
    char *out = ps_to_cstr(buf, a.len);
    free(buf);
    free(a.cps);
    return out;
}

// 首码位抬升只覆盖 ASCII：非 ASCII 字母无大小写表，保持原样。
char *ps_capitalized(const char *s) {
    ps_text a = ps_from_cstr(s);
    if (a.len == 0) {
        char *out = ps_to_cstr(NULL, 0);
        free(a.cps);
        return out;
    }
    uint32_t first = a.cps[0];
    if (first >= 'a' && first <= 'z') {
        a.cps[0] = first - ('a' - 'A');
    }
    char *out = ps_copy(&a, 0, a.len);
    free(a.cps);
    return out;
}

// 左右均分填充，奇数余量给右侧；空填充或已够宽原样返回。
char *ps_center(const char *s, int32_t width, const char *fill_text) {
    ps_text a = ps_from_cstr(s);
    ps_text f = ps_from_cstr(fill_text);
    if (width <= 0 || f.len == 0 || a.len >= (size_t)width) {
        char *out = ps_copy(&a, 0, a.len);
        free(a.cps);
        free(f.cps);
        return out;
    }
    size_t need = (size_t)width - a.len;
    size_t left = need / 2;
    size_t right = need - left;
    size_t llen = 0;
    size_t rlen = 0;
    uint32_t *lpad = ps_fill(&f, left, &llen);
    uint32_t *rpad = ps_fill(&f, right, &rlen);
    uint32_t *buf = (uint32_t *)malloc((llen + a.len + rlen + 1) * sizeof(uint32_t));
    if (lpad == NULL || rpad == NULL || buf == NULL) {
        free(lpad);
        free(rpad);
        free(buf);
        free(a.cps);
        free(f.cps);
        return NULL;
    }
    memcpy(buf, lpad, llen * sizeof(uint32_t));
    memcpy(buf + llen, a.cps, a.len * sizeof(uint32_t));
    memcpy(buf + llen + a.len, rpad, rlen * sizeof(uint32_t));
    char *out = ps_to_cstr(buf, llen + a.len + rlen);
    free(lpad);
    free(rpad);
    free(buf);
    free(a.cps);
    free(f.cps);
    return out;
}

// 取前 width 个码位；非正宽度得空串，越界得原串。
char *ps_truncate(const char *s, int32_t width) {
    ps_text a = ps_from_cstr(s);
    size_t to = 0;
    if (width > 0) {
        to = (size_t)width < a.len ? (size_t)width : a.len;
    }
    char *out = ps_copy(&a, 0, to);
    free(a.cps);
    return out;
}

void ps_free(void *p) {
    free(p);
}
