#!/bin/bash
### set_image.sh — 穿云投屏镜像版本策略（钉死 / 跟随最新）
###
### 【为什么要钉死】
### 上游镜像只发 :latest，没有语义化版本 tag。如果我们跟随 :latest，上游一旦
### 发布 0.4.2（甚至破坏性变更），后来安装的用户会直接拉到新镜像，而包里的
### 配置/脚本还是按旧版本写的 —— 结果就是「装完就坏」。
### 所以默认 **按 digest 钉死** 我们在真机上验证过的那个版本：
###   · digest 不可变，上游更新 :latest 完全不影响已装与新装用户；
###   · 升级变成一个显式动作（set_image.sh --upgrade），先拉取→冒烟校验→再切换，
###     失败自动回退，不会把用户弄坏。
###
### 用法：
###   set_image.sh --show                 查看当前镜像 / digest / 策略
###   set_image.sh --apply                按当前策略写 compose 的 image: 行（幂等）
###   set_image.sh --upgrade              拉取上游 :latest → 冒烟校验 → 切到新 digest（失败回退）
###   set_image.sh --follow-latest        改为跟随 :latest（不推荐，需自担上游变更风险）
###   set_image.sh --pin <sha256:...>     手动钉死某个 digest
###
### 配置优先级：$VAR_DIR/image.conf  >  app/docker/runtime.conf 默认值

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/cloudphone/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/cloudphone/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
CONF="$VAR_DIR/image.conf"
LOG="$VAR_DIR/image.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true

if [ -f "$APP_DIR/scripts/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$APP_DIR/scripts/rtconf.sh"
    rtconf_load
fi
: "${WEBRTC_REPO:=buutuu/scrcpy-over-webrtc}"
: "${ACCEL_PREFIX:=docker.fnnas.com}"
: "${WEBRTC_DIGEST:=}"
: "${WEBRTC_PIN:=1}"
: "${CACHE_PREFIX:=cloudphone-cache}"
: "${PINNED_WEBRTC:=${CACHE_PREFIX}/webrtc:pinned}"

### 用户覆盖（var/image.conf）
if [ -f "$CONF" ]; then
    _v=$(sed -n 's/^PIN=//p' "$CONF" | head -n1);  [ -n "$_v" ] && WEBRTC_PIN="$_v"
    _v=$(sed -n 's/^DIGEST=//p' "$CONF" | head -n1); [ -n "$_v" ] && WEBRTC_DIGEST="$_v"
fi
case "$WEBRTC_PIN" in 0|false|false|no) WEBRTC_PIN=0 ;; *) WEBRTC_PIN=1 ;; esac

cur_ref(){
    # compose 恒引用本地稳定 tag（见 runtime.conf PINNED_WEBRTC 的说明）：
    # 钉死/跟随只影响 pull_image.sh 拉哪个内容，不影响 compose 的引用形式。
    printf '%s' "${PINNED_WEBRTC:-${CACHE_PREFIX:-cloudphone-cache}/webrtc:pinned}"
}

write_conf(){
    {
        echo "PIN=$WEBRTC_PIN"
        [ -n "$WEBRTC_DIGEST" ] && echo "DIGEST=$WEBRTC_DIGEST"
        echo "UPDATED=$(date '+%F %T')"
    } > "$CONF" 2>/dev/null || true
}

write_compose(){
    local ref; ref="$(cur_ref)"
    [ -f "$COMPOSE" ] || { echo "set_image: compose 不存在：$COMPOSE" >&2; return 1; }
    sed -i -E "s|^([[:space:]]*image:[[:space:]]*).*(scrcpy-over-webrtc).*\$|\1${ref}|" "$COMPOSE"
    mkdir -p /docker 2>/dev/null || true
    cp -f "$COMPOSE" /docker/docker-compose.yaml 2>/dev/null || true
    chmod 644 /docker/docker-compose.yaml 2>/dev/null || true
    echo "set_image: compose image 行 = $ref"
}

smoke(){
    local ref="$1"
    docker run --rm --entrypoint /bin/sh "$ref" -c \
        'test -f /app/entrypoint.sh && test -x /app/webrtc-signaling && test -x /usr/bin/turnserver' \
        >/dev/null 2>&1
}

SHOW=0; APPLY=0; UPGRADE=0; FOLLOW=0; NEWDIGEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --show)          SHOW=1; shift ;;
        --apply)         APPLY=1; shift ;;
        --upgrade)       UPGRADE=1; shift ;;
        --follow-latest) FOLLOW=1; shift ;;
        --pin)           NEWDIGEST="${2:-}"; shift 2 ;;
        -h|--help)       sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
done

if [ "$SHOW" = "1" ]; then
    echo "策略        : $([ "$WEBRTC_PIN" = "1" ] && echo '钉死 digest（推荐）' || echo '跟随 :latest')"
    echo "当前镜像引用: $(cur_ref)"
    echo "digest      : ${WEBRTC_DIGEST:-（未钉死）}"
    echo "本地镜像    : $(docker image inspect -f '{{.Id}}' "$(cur_ref)" 2>/dev/null || echo '不存在')"
    exit 0
fi

if [ "$FOLLOW" = "1" ]; then
    WEBRTC_PIN=0; write_conf
    echo "set_image: 已切换为「跟随 :latest」。注意：上游破坏性变更会直接生效。"
    APPLY=1
fi

if [ -n "$NEWDIGEST" ]; then
    case "$NEWDIGEST" in sha256:*) : ;; *) echo "digest 应以 sha256: 开头" >&2; exit 1 ;; esac
    WEBRTC_PIN=1; WEBRTC_DIGEST="$NEWDIGEST"; write_conf
    echo "set_image: 已钉死 $NEWDIGEST"
    # 换了 digest 必须把新内容拉下来并刷新本地稳定 tag，否则 compose 仍指向旧镜像
    if [ -f "$APP_DIR/scripts/pull_image.sh" ]; then
        bash "$APP_DIR/scripts/pull_image.sh" --force 2>&1 | sed 's/^/  /' || true
    fi
    APPLY=1
fi

if [ "$UPGRADE" = "1" ]; then
    {
        echo "==== set_image --upgrade $(date '+%F %T') ===="
    } >>"$LOG" 2>&1
    OLD_ID="$(docker image inspect -f '{{.Id}}' "$(cur_ref)" 2>/dev/null | head -n1)"
    echo "set_image: 拉取上游 :latest ..."
    PULLED=""
    for SRC in "$ACCEL_PREFIX" "docker.m.daocloud.io" "docker.1ms.run" ""; do
        if [ -n "$SRC" ]; then CAND="$SRC/$WEBRTC_REPO:latest"; else CAND="$WEBRTC_REPO:latest"; fi
        if timeout 900 docker pull "$CAND" >/dev/null 2>&1; then PULLED="$CAND"; break; fi
    done
    if [ -z "$PULLED" ]; then
        echo "set_image: 所有源均拉取失败，保持现有版本不变"
        { echo "拉取失败，保持现有版本"; } >>"$LOG" 2>&1
        exit 1
    fi
    NEW_ID="$(docker image inspect -f '{{.Id}}' "$PULLED" 2>/dev/null | head -n1)"
    if [ -n "$OLD_ID" ] && [ "$NEW_ID" = "$OLD_ID" ]; then
        echo "set_image: 已是最新（ID 未变化）"
        exit 0
    fi
    if ! smoke "$PULLED"; then
        echo "set_image: 新镜像冒烟校验失败（缺 entrypoint/signaling/turnserver），不采用"
        { echo "冒烟校验失败，不采用"; } >>"$LOG" 2>&1
        exit 1
    fi
    WEBRTC_PIN=1
    WEBRTC_DIGEST="$(docker image inspect -f '{{index .RepoDigests 0}}' "$PULLED" 2>/dev/null \
                     | sed "s|^.*@||")"
    if [ -z "$WEBRTC_DIGEST" ]; then
        echo "set_image: 未能取得新镜像 digest，保持现有版本"
        exit 1
    fi
    write_conf
    # 关键：新版本镜像必须打上 compose 实际引用的本地稳定 tag，否则 compose 还是跑旧镜像
    docker tag "$PULLED" "${PINNED_WEBRTC:-${CACHE_PREFIX}/webrtc:pinned}" 2>/dev/null || true
    echo "set_image: 已切换到新 digest $WEBRTC_DIGEST"
    { echo "升级到 $WEBRTC_DIGEST"; } >>"$LOG" 2>&1
    APPLY=1
fi

if [ "$APPLY" = "1" ]; then
    # 兜底：本地稳定 tag 不存在就先拉（首次安装/镜像被清理的场景）
    if ! docker image inspect "${PINNED_WEBRTC:-${CACHE_PREFIX}/webrtc:pinned}" >/dev/null 2>&1 \
       && [ -f "$APP_DIR/scripts/pull_image.sh" ]; then
        bash "$APP_DIR/scripts/pull_image.sh" 2>&1 | sed 's/^/  /' || true
    fi
    write_compose
fi

exit 0
