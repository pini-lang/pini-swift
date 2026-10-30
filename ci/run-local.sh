#!/usr/bin/env bash
# 在本机跑一遍与 CI 完全相同的 Linux 流水线。
#
# 为什么复制一份再挂载：容器内构建会在仓里留下 Linux 的 .build，覆盖掉本机 macOS 的构建缓存。
# 复制体只有十几兆（不含 .build），代价远小于「跑一次 CI 就把本地增量构建废掉」。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="${PINI_CI_IMAGE:-pini-ci:local}"
work="$(mktemp -d "${TMPDIR:-/tmp}/pini-ci.XXXXXX")"
trap 'rm -rf "$work"' EXIT

printf '镜像: %s\n工作副本: %s\n' "$image" "$work"

docker build -f "$repo_root/ci/Dockerfile" -t "$image" "$repo_root"

# 排除构建产物与编辑器状态；.git 要带上，文档链接门禁靠它判「引用空缺载体」。
tar -C "$repo_root" \
    --exclude ./.build \
    --exclude ./.swiftpm \
    --exclude ./.DS_Store \
    -cf - . | tar -C "$work" -xf -

docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$work":/src -w /src "$image"
