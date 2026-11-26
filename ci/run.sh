#!/usr/bin/env bash
# 跑一遍完整的 Linux 流水线：构建镜像 → 同步工作树 → 起容器跑 ci/entrypoint.sh。
# 本地与远端共用这一份 —— GitHub Actions 那一步也只有 `bash ci/run.sh`。
# 档位走 PINI_CI_TIER：full（默认，含全部用例）与 build（只到自举奠基）。
#
# 同步而非直接挂载：容器里的 Linux `.build` 会盖掉宿主的 macOS 增量缓存。
# 工作副本固定在一处，`bootstrap/.build` 因此跨轮保留，自举编译器付增量而不是每轮全量重建。
# 根 `.build` 另挂宿主缓存；Actions 每次新 runner，只有 gha 层缓存能带过 apt 那一层。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="${PINI_CI_IMAGE:-pini-ci:local}"
cache_dir="${PINI_CI_BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pini-ci-build}"
work="${PINI_CI_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/pini-ci-work}"
mkdir -p "$cache_dir" "$work"

# 同一棵固定树只许一轮 CI 写；锁在副本旁边，进程退出即删。
#  注意  上一轮被强杀会留下锁目录，确认没有 docker 进程后手工删掉再重跑。
lock="${work}.lock"
if ! mkdir "$lock" 2>/dev/null; then
    echo " 行不通  [容器] 另一轮 CI 正占用 $work；结束或删掉 $lock 后重试" >&2
    exit 1
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

printf '镜像: %s\n工作副本: %s（固定）\n构建缓存: %s\n' "$image" "$work" "$cache_dir"

# 重复验证只跑容器、不重建镜像：`PINI_CI_SKIP_BUILD=1` 且镜像已在时跳过构建。
#  注意  跳过意味着镜像可能落后于 `ci/Dockerfile`；镜像缺失时仍会建，不会拿空壳跑出假绿。
if [ "${PINI_CI_SKIP_BUILD:-}" = "1" ] && docker image inspect "$image" >/dev/null 2>&1; then
    printf '跳过构建：%s 已在（PINI_CI_SKIP_BUILD=1）\n' "$image"
else
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        docker buildx build --load \
            --cache-from type=gha --cache-to type=gha,mode=min \
            -f "$repo_root/ci/Dockerfile" -t "$image" "$repo_root"
    else
        docker build -f "$repo_root/ci/Dockerfile" -t "$image" "$repo_root"
    fi
fi

# 增量同步：--delete 清掉源已删的项；构建产物全部排除，留给容器跨轮复用。
#  注意  bootstrap/.build 是自举编译器产物，宿主那份是 macOS 的，不能带进 Linux 副本。
if ! command -v rsync >/dev/null 2>&1; then
    echo " 行不通  [容器] 缺 rsync，工作副本无法增量同步" >&2
    exit 1
fi
rsync -a --delete \
    --exclude '/.build' \
    --exclude '/bootstrap/.build' \
    --exclude '/.swiftpm' \
    --exclude '.DS_Store' \
    "$repo_root"/ "$work"/

# 不以 root 跑：只读文件的权限判据在 root 下恒真，那一条会退化成空判。
# HOME 指到 /tmp：容器用户与宿主同 UID，但没有对应的家目录。
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e PINI_CI_TIER="${PINI_CI_TIER:-full}" \
    -v "$work":/src -w /src \
    -v "$cache_dir":/src/.build \
    "$image"
