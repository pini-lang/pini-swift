#!/usr/bin/env bash
# tools/runtime-lib.sh — 运行时段动态库的唯一定位点，被构建与三个测试脚本共用。
# 自举产物每次值操作都跨 C ABI 进这个库；debug 构建带独占访问检查与未优化 ARC，实测慢五倍。
# 只认 release 构建，缺文件即报错：静默回退 debug 会让整套门禁慢五倍却不红。

pini_runtime_lib() {
    local root="$1"
    local dir="$root/.build/release"
    local name
    for name in libPiniRuntime.dylib libPiniRuntime.so; do
        if [ -f "$dir/$name" ]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    echo " 行不通  [运行时段] 缺 $dir/libPiniRuntime.{dylib,so}；先 swift build -c release --disable-sandbox --product PiniRuntime" >&2
    return 1
}
