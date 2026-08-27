// ffilib — Pini ffi_module 示例的「项目内」外部依赖库（vendored dependency）。
//
// 目的：让 FFI 示例不再依赖宿主机的隐式 libc 解析（`dlopen(nil)`）或写死的系统
// search_paths（如 /opt/homebrew/lib、/usr/local/lib），从而可在任意检出位置、
// 任意调用 cwd 下独立运行。`module.toml` 的 `[ffi] search_paths = ["lib"]` 会解析到
// 本目录，loader 据此 `dlopen` 这里的 `libffilib.{dylib,so}`。
//
// 导出符号（薄封装，仅转发到 C 标准库，便于演示「配置 + 调用外来接口」链路）：
//   ffi_malloc / ffi_free / ffi_strlen / ffi_puts / ffi_memcpy / ffi_memset /
//   ffi_atoi / ffi_strcmp
//
// 构建（macOS）：  cc -shared -o libffilib.dylib ffilib.c
// 构建（Linux）：  cc -shared -fPIC -o libffilib.so ffilib.c
//
// 注：本库仅作示例依赖 vendoring 演示，二进制体积小（约十几 KB），随仓库提交；
// 上层 Pini 源码经 `cstr` shim 把 String 转为 *U8 后传入此处符号。

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

void*  ffi_malloc(size_t size)                          { return malloc(size); }
void   ffi_free(void* p)                                { free(p); }
size_t ffi_strlen(const char* s)                        { return strlen(s); }
int    ffi_puts(const char* s)                          { return puts(s); }
void*  ffi_memcpy(void* dst, const void* src, size_t n) { return memcpy(dst, src, n); }
void*  ffi_memset(void* p, int v, size_t n)             { return memset(p, v, n); }
int    ffi_atoi(const char* s)                          { return atoi(s); }
int    ffi_strcmp(const char* a, const char* b)         { return strcmp(a, b); }
