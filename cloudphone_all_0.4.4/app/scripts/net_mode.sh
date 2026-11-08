#!/bin/bash
### net_mode.sh — 一键切换访问模式（局域网直连 / 公网端口映射 / 内网穿透·反向代理）
###
### 用法：
###   net_mode.sh lan                        # 局域网直连（默认，HTTPS）
###   net_mode.sh lanhttp                    # 局域网直连，强制 HTTP（免自签证书提示）
###   net_mode.sh wan  <域名或公网IP> [端口]  # 公网端口映射（HTTPS，需 UDP 可达）
###   net_mode.sh proxy <域名或IP>    [端口]  # 内网穿透/反向代理（HTTP，TCP 单端口）
###   net_mode.sh <模式> ... --no-restart     # 只写配置不重建容器（安装/升级阶段用）
###   net_mode.sh                            # 不带参数：按已保存配置重新应用（幂等）
###
### 作用：只修改 PUBLIC_IP / USE_TLS 两个环境变量，并调用 apply_ports.sh 同步端口；
###       随后按需重建画面服务容器（数据卷保持不变）。
###
### 为什么默认 HTTPS：本应用的 Agent 跑在真实手机上，上游 Agent 支持 wss，
###   默认加密可避免公网暴露时控制流与画面帧明文传输。

set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/cloudphone/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/cloudphone/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
CONF="$VAR_DIR/net.conf"
mkdir -p "$VAR_DIR" 2>/dev/null || true

NO_RESTART=0
ARGS=""
for a in "$@"; do
    if [ "$a" = "--no-restart" ]; then NO_RESTART=1; else ARGS="$ARGS $a"; fi
done
# shellcheck disable=SC2086
set -- $ARGS

MODE="${1:-}"
HOST_ARG="${2:-}"
PORT_ARG="${3:-}"

### 局域网 IP：不能用 `hostname -I | awk '{print $1}'` 的第一个 ——
### 实测会取到 docker 网桥（172.18.0.1），导致 coturn external-ip 与 ICE 候选不可达。
_NET_UTIL="$(cd "$(dirname "$0")" && pwd)/net_util.sh"
if [ -f "$_NET_UTIL" ]; then
    # shellcheck disable=SC1090
    . "$_NET_UTIL"
fi
if command -v cp_lan_ip >/dev/null 2>&1; then
    LAN_IP="$(cp_lan_ip)"
else
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[ -z "$LAN_IP" ] && LAN_IP="127.0.0.1"

### 端口取自 ports.conf（apply_ports.sh 负责写入 compose 的映射）
PORTS_CONF="$VAR_DIR/ports.conf"
P_WEB="8443"; P_EXT=""
if [ -f "$PORTS_CONF" ]; then
    _v=$(sed -n 's/^WEB_PORT=//p' "$PORTS_CONF" | head -n1); [ -n "$_v" ] && P_WEB="$_v"
    _v=$(sed -n 's/^EXT_PORT=//p' "$PORTS_CONF" | head -n1); [ -n "$_v" ] && P_EXT="$_v"
fi
case "$P_WEB" in ''|*[!0-9]*) P_WEB=8443 ;; esac
case "$P_EXT" in ''|*[!0-9]*) P_EXT="" ;; esac

OLD_MODE=""; OLD_HOST=""; OLD_PORT=""
if [ -f "$CONF" ]; then
    OLD_MODE=$(sed -n 's/^MODE=//p' "$CONF" | head -n1)
    OLD_HOST=$(sed -n 's/^HOST=//p' "$CONF" | head -n1)
    OLD_PORT=$(sed -n 's/^PORT=//p' "$CONF" | head -n1)
fi
[ -z "$MODE" ] && MODE="${OLD_MODE:-lan}"

case "$MODE" in
    lan)
        PUB="$LAN_IP"; TLS="true";  EXT="${P_EXT:-$P_WEB}"; HOST_SAVE=""; PORT_SAVE="$EXT"
        ;;
    lanhttp)
        ### 手机浏览器 / App 内嵌 WebView 对自签证书会拦截或白屏时使用（仅限可信局域网）
        PUB="$LAN_IP"; TLS="false"; EXT="${P_EXT:-$P_WEB}"; HOST_SAVE=""; PORT_SAVE="$EXT"
        ;;
    wan)
        PUB="${HOST_ARG:-${OLD_HOST:-$LAN_IP}}"
        EXT="${PORT_ARG:-${OLD_PORT:-${P_EXT:-$P_WEB}}}"
        TLS="true"; HOST_SAVE="$PUB"; PORT_SAVE="$EXT"
        ;;
    proxy)
        PUB="${HOST_ARG:-${OLD_HOST:-$LAN_IP}}"
        EXT="${PORT_ARG:-${OLD_PORT:-${P_EXT:-443}}}"
        TLS="false"; HOST_SAVE="$PUB"; PORT_SAVE="$EXT"
        ;;
    *)
        echo "net_mode: 未知模式 '$MODE'（可用：lan|lanhttp|wan|proxy）" >&2
        exit 1
        ;;
esac

### coturn 的 external-ip 只接受 IP。用户常填域名（公网/穿透场景），
### 直接写进 PUBLIC_IP 会让画面服务启动异常（表现为「局域网能用、公网/穿透打不开」）。
### 这里把「对外主机」与「PUBLIC_IP」分离：net.conf 保留域名用于面板链接，
### 传给容器的 PUBLIC_IP 一律用可解析到的 IP。
PUBLIC_IP_FOR_CONTAINER="$PUB"
case "$PUB" in
    ''|*[!0-9.]*)   ### 不是 IPv4（视为域名）
        RESOLVED=""
        if command -v getent >/dev/null 2>&1; then
            RESOLVED=$(getent hosts "$PUB" 2>/dev/null | awk '{print $1; exit}')
        fi
        if [ -z "$RESOLVED" ] && command -v nslookup >/dev/null 2>&1; then
            RESOLVED=$(nslookup "$PUB" 2>/dev/null | awk '/^Address: /{print $2; exit}')
        fi
        if [ -n "$RESOLVED" ]; then
            PUBLIC_IP_FOR_CONTAINER="$RESOLVED"
            echo "net_mode: 域名 $PUB 解析为 $RESOLVED（写入容器的 PUBLIC_IP 用 IP，面板地址仍用域名）"
        else
            DETECTED_PUB=""
            [ -f "$VAR_DIR/net-detect.conf" ] && DETECTED_PUB=$(sed -n 's/^PUBLIC_IP=//p' "$VAR_DIR/net-detect.conf" 2>/dev/null | head -n1)
            case "$DETECTED_PUB" in ''|*[!0-9.]*) DETECTED_PUB="$LAN_IP" ;; esac
            PUBLIC_IP_FOR_CONTAINER="$DETECTED_PUB"
            echo "net_mode: 域名 $PUB 无法解析，容器 PUBLIC_IP 回退为 $PUBLIC_IP_FOR_CONTAINER（面板地址仍用域名 $PUB）"
        fi
        ;;
esac

### 写配置文件（供面板显示与后续重放）
{
    echo "MODE=$MODE"
    echo "HOST=$HOST_SAVE"
    echo "PORT=$PORT_SAVE"
    echo "UPDATED=$(date '+%F %T')"
} > "$CONF" 2>/dev/null || true

[ -f "$COMPOSE" ] || { echo "net_mode: compose 不存在：$COMPOSE"; exit 0; }

### 修改 environment 块中的 PUBLIC_IP / USE_TLS：先删旧行，再在 environment: 后插入
TMP="$(mktemp)" || exit 0
awk -v pub="$PUBLIC_IP_FOR_CONTAINER" -v tls="$TLS" '
    /^[[:space:]]*-[[:space:]]*(PUBLIC_IP|USE_TLS)=/ { next }
    { print }
    /^[[:space:]]*environment:[[:space:]]*$/ && !done {
        print "      - PUBLIC_IP=" pub
        print "      - USE_TLS=" tls
        done=1
    }
' "$COMPOSE" > "$TMP" && mv -f "$TMP" "$COMPOSE" 2>/dev/null || rm -f "$TMP"

### 端口映射与对外通告值（幂等；不重启）
if [ -f "$APP_DIR/scripts/apply_ports.sh" ]; then
    bash "$APP_DIR/scripts/apply_ports.sh" --no-restart >/dev/null 2>&1 || true
fi

### 同步到 /docker（飞牛 docker-project 读取该路径）
mkdir -p /docker 2>/dev/null || true
cp -f "$COMPOSE" /docker/docker-compose.yaml 2>/dev/null || true
chmod 644 /docker/docker-compose.yaml 2>/dev/null || true

echo "net_mode[$MODE]: PUBLIC_IP(容器)=$PUBLIC_IP_FOR_CONTAINER USE_TLS=$TLS 对外端口=$EXT"

if [ "$NO_RESTART" = "1" ]; then
    echo "net_mode: --no-restart，仅写配置（安装/升级流程稍后统一启动容器）"
    exit 0
fi

### 重建画面服务容器使环境变量生效（数据卷 cloudphone-webrtc-data 不变）
if docker inspect cloudphone-webrtc >/dev/null 2>&1; then
    ( cd "$APP_DIR/docker" 2>/dev/null && docker compose -p cloudphone up -d --force-recreate webrtc ) >/dev/null 2>&1 \
        && echo "net_mode: 画面服务已按新模式重建" || echo "net_mode: 重建失败（可稍后在应用中心重启应用）"
else
    echo "net_mode: 容器尚未创建，配置已就绪，启动时自动生效"
fi

exit 0
