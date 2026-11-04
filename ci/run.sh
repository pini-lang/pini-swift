#!/usr/bin/env bash
# 跑一遍完整的 Linux 流水线：构建镜像 → 复制工作树 → 起容器跑 ci/entrypoint.sh。
# 本地与远端共用这一份 —— GitHub Actions 那一步也只有 `bash ci/run.sh`。
#
# 复制而非直接挂载：容器里的 Linux `.build` 会盖掉宿主的 macOS 增量缓存。
# 构建缓存分两路：Actions 每次都是新 runner，只有 gha 层缓存能带过 apt 那一层；
# 本机把宿主缓存目录挂成 `.build`，第二次跑只付增量，也不污染仓里那份。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="${PINI_CI_IMAGE:-pini-ci:local}"
cache_dir="${PINI_CI_BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pini-ci-build}"
work="$(mktemp -d "${TMPDIR:-/tmp}/pini-ci.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$cache_dir"
printf '镜像: %s\n工作副本: %s\n构建缓存: %s\n' "$image" "$work" "$cache_dir"

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    docker buildx build --load \
        --cache-from type=gha --cache-to type=gha,mode=min \
        -f "$repo_root/ci/Dockerfile" -t "$image" "$repo_root"
else
    docker build -f "$repo_root/ci/Dockerfile" -t "$image" "$repo_root"
fi

# 排除构建产物与编辑器状态；.git 要带上，文档链接门禁靠它判「引用空缺载体」。
tar -C "$repo_root" \
    --exclude ./.build \
    --exclude ./.swiftpm \
    --exclude ./.DS_Store \
    -cf - . | tar -C "$work" -xf -

# 不以 root 跑：只读文件的权限判据在 root 下恒真，那一条会退化成空判。
# HOME 指到 /tmp：容器用户与宿主同 UID，但没有对应的家目录。
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$work":/src -w /src \
    -v "$cache_dir":/src/.build \
    "$image"
