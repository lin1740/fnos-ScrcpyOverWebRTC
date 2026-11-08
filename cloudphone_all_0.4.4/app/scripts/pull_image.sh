#!/bin/bash
### pull_image.sh — 确保穿云投屏镜像就绪（加速源优先 → 官方回退）
###
### 版本策略（runtime.conf 的 WEBRTC_PIN）：
###   PIN=1（默认）→ 按 WEBRTC_DIGEST 拉取钉死的 digest（内容不可变，上游更新不影响本应用）
###   PIN=0        → 跟随 :latest（自担上游变更风险）
###
### 【为什么拉完要打成本地 tag】
### compose 里引用的是本地稳定 tag（runtime.conf 的 PINNED_WEBRTC），不是 @sha256 引用。
### 原因：compose 的 image 写成 <registry>/<repo>@sha256:... 时，docker 会把它当独立
### 引用找本地镜像；本地只有 tag 别名时会联网 pull，而 fnOS 镜像源对 digest 路径返回
### 401 → 建不出容器 → 应用中心启用报 12005「no container to start」。
### 所以：这里负责把正确版本拉下来并打上 PINNED_WEBRTC，compose 启动永不联网。
###
### 用法：
###   pull_image.sh            # 本地已有 PINNED_WEBRTC 则直接返回
###   pull_image.sh --force    # 强制重新拉取并刷新 PINNED_WEBRTC
###
### 退出码：0 = 镜像就绪；1 = 所有源均失败

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$HERE/rtconf.sh"
    rtconf_load
fi
: "${WEBRTC_REPO:=buutuu/scrcpy-over-webrtc}"
: "${WEBRTC_TAG:=latest}"
: "${ACCEL_PREFIX:=docker.fnnas.com}"
: "${WEBRTC_PIN:=1}"
: "${WEBRTC_DIGEST:=}"
: "${CACHE_PREFIX:=cloudphone-cache}"
: "${PINNED_WEBRTC:=${CACHE_PREFIX}/webrtc:pinned}"
: "${CANON_WEBRTC:=${ACCEL_PREFIX}/${WEBRTC_REPO}:${WEBRTC_TAG}}"
: "${OFF_WEBRTC:=${WEBRTC_REPO}:${WEBRTC_TAG}}"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

img_id(){ docker image inspect -f '{{.Id}}' "$1" 2>/dev/null | head -n1; }
retag_all(){  # 统一打上本地稳定 tag 与排障用别名
    local src="$1"
    docker tag "$src" "$PINNED_WEBRTC" 2>/dev/null || true
    docker tag "$src" "$CANON_WEBRTC" 2>/dev/null || true
    docker tag "$src" "$OFF_WEBRTC" 2>/dev/null || true
}

if [ "$FORCE" != "1" ] && docker image inspect "$PINNED_WEBRTC" >/dev/null 2>&1; then
    # 版本钉死校验：本地稳定 tag 的内容必须是钉死 digest 对应的镜像。
    # digest 是内容寻址的——镜像内容不同则 digest 必然不同，因此用 RepoDigests
    # 比对即可发现「有人手动拉了别的版本打上 pinned tag」或「上游 :latest 已更新但
    # 本地仍是旧版」等一切不一致，发现即按钉死 digest 重新拉取纠正。
    # 也就是说：上游发布新版不会影响本应用，拉取永远按包内钉死的 0.4.4 digest 走。
    if [ "$WEBRTC_PIN" = "1" ] && [ -n "$WEBRTC_DIGEST" ]; then
        _rd=$(docker image inspect -f '{{range .RepoDigests}}{{.}}
{{end}}' "$PINNED_WEBRTC" 2>/dev/null)
        case "$_rd" in
            *"@$WEBRTC_DIGEST"*)
                echo "镜像已就绪且与钉死版本一致（digest 校验通过）：$PINNED_WEBRTC"
                exit 0
                ;;
            *)
                echo "警告：本地 $PINNED_WEBRTC 的内容与钉死 digest 不符，重新按钉死版本拉取纠正..."
                ;;
        esac
    else
        echo "镜像已就绪：$PINNED_WEBRTC"
        exit 0
    fi
fi

### 拉取候选：钉死时用 digest 引用；否则用 tag
PULL_REFS=()
if [ "$WEBRTC_PIN" = "1" ] && [ -n "$WEBRTC_DIGEST" ]; then
    # 飞牛源优先（实测按 digest 拉取可用、RepoDigest 保留目标 digest）；daocloud/1ms 仅作兜底
    for SRC in "$ACCEL_PREFIX" "docker.m.daocloud.io" "docker.1ms.run" ""; do
        if [ -n "$SRC" ]; then PULL_REFS+=("$SRC/$WEBRTC_REPO@$WEBRTC_DIGEST")
        else PULL_REFS+=("$WEBRTC_REPO@$WEBRTC_DIGEST"); fi
    done
else
    for SRC in "$ACCEL_PREFIX" "docker.m.daocloud.io" "docker.1ms.run" ""; do
        if [ -n "$SRC" ]; then PULL_REFS+=("$SRC/$WEBRTC_REPO:$WEBRTC_TAG")
        else PULL_REFS+=("$WEBRTC_REPO:$WEBRTC_TAG"); fi
    done
fi

BEFORE="$(img_id "$PINNED_WEBRTC")"
OK=""
for REF in "${PULL_REFS[@]}"; do
    echo "[$(date '+%F %T')] 准备镜像：$REF"
    if timeout 900 docker pull "$REF" >/dev/null 2>&1; then
        OK="$REF"
        retag_all "$REF"
        break
    fi
done

if [ -z "$OK" ]; then
    # 兜底：本地若已有同名 tag 的旧镜像，也能顶上去（宁可先能跑，也别卡住安装）
    if docker image inspect "$CANON_WEBRTC" >/dev/null 2>&1; then
        echo "所有源不可达，改用本地已有镜像：$CANON_WEBRTC" >&2
        retag_all "$CANON_WEBRTC"
        exit 0
    fi
    echo "所有加速源与 Docker Hub 官方源均不可达：$OFF_WEBRTC" >&2
    exit 1
fi

AFTER="$(img_id "$PINNED_WEBRTC")"
if [ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ]; then
    echo "镜像已是最新（ID 未变化）：$PINNED_WEBRTC"
else
    echo "镜像就绪：$PINNED_WEBRTC ← $OK"
fi
exit 0
