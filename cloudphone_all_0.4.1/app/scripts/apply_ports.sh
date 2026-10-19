#!/bin/bash
### apply_ports.sh — 把 ports.conf 里的端口写进 compose（端口映射 + 对外通告变量）
###
### 用法：
###   bash apply_ports.sh                 # 写入 compose 并同步到 /docker，重建容器
###   bash apply_ports.sh --no-restart    # 只写配置（安装/升级流程稍后统一启动）
###   bash apply_ports.sh --check         # 只做占用预检，不写任何文件（安装前调用）
###
### ports.conf 键：
###   WEB_PORT=8443           画面/信令对外端口（容器内固定 8443）
###   TURN_PORT=3478          TURN 对外端口（容器内固定 3478）
###   RELAY_MIN/RELAY_MAX     媒体中继段（容器内外必须一致，coturn 不支持端口转换）
###
### 设计说明：容器内监听端口永远不变，只改「宿主对外映射」与「对外通告值」。
### 这样用户改端口不会影响容器内部逻辑，也不会动数据卷。

set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/cloudphone/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/cloudphone/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
CONF="$VAR_DIR/ports.conf"
mkdir -p "$VAR_DIR" 2>/dev/null || true

NO_RESTART=0
CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --no-restart) NO_RESTART=1 ;;
        --check)      CHECK_ONLY=1 ;;
        *) echo "未知参数：$a（可用：--no-restart / --check）" >&2; exit 1 ;;
    esac
done

cur(){ sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1; }

WEB="$(cur WEB_PORT)";   [ -n "$WEB" ]   || WEB=8443
TURN="$(cur TURN_PORT)"; [ -n "$TURN" ]  || TURN=3478
RMIN="$(cur RELAY_MIN)"; [ -n "$RMIN" ]  || RMIN=50000
RMAX="$(cur RELAY_MAX)"; [ -n "$RMAX" ]  || RMAX=50100

case "$WEB"  in ''|*[!0-9]*) WEB=8443 ;; esac
case "$TURN" in ''|*[!0-9]*) TURN=3478 ;; esac
case "$RMIN" in ''|*[!0-9]*) RMIN=50000 ;; esac
case "$RMAX" in ''|*[!0-9]*) RMAX=50100 ;; esac
if [ "$RMIN" -gt "$RMAX" ]; then _t="$RMIN"; RMIN="$RMAX"; RMAX="$_t"; fi

### ── 占用预检 ────────────────────────────────────────────────────────────────
### 为什么必须预检：Docker 发布端口是「逐个绑定」，中继段里只要有一个被占，
### 整段映射就会失败、容器停在 Created 起不来（现象是「装好了但设备永不上线」）。
check_ports() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "check: 未找到 python3，跳过占用预检"
        return 0
    fi
    python3 - "$WEB" "$TURN" "$RMIN" "$RMAX" <<'PY'
import socket, sys
web, turn, rmin, rmax = (int(x) for x in sys.argv[1:5])
conflicts = []

def try_tcp(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", p)); return True
    except OSError:
        return False
    finally:
        s.close()

def try_udp(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("0.0.0.0", p)); return True
    except OSError:
        return False
    finally:
        s.close()

if not try_tcp(web):
    conflicts.append("画面端口 %d/TCP" % web)
if not try_tcp(turn):
    conflicts.append("TURN 端口 %d/TCP" % turn)
if not try_udp(turn):
    conflicts.append("TURN 端口 %d/UDP" % turn)
bad = [p for p in range(rmin, rmax + 1) if not try_udp(p)]
if bad:
    head = ", ".join(str(x) for x in bad[:8])
    more = "" if len(bad) <= 8 else " 等 %d 个" % len(bad)
    conflicts.append("中继段 %d-%d/UDP 中已有占用：%s%s" % (rmin, rmax, head, more))

if conflicts:
    print("PORT_CONFLICT:" + "；".join(conflicts))
    sys.exit(1)
print("PORT_OK:%d/%d/%d-%d" % (web, turn, rmin, rmax))
PY
}

if [ "$CHECK_ONLY" = "1" ]; then
    check_ports
    exit $?
fi

### ── 写入 compose ────────────────────────────────────────────────────────────
[ -f "$COMPOSE" ] || { echo "apply_ports: compose 不存在：$COMPOSE" >&2; exit 1; }

sed -i \
    -e "s|^\( *- \"\)[0-9]*:8443/tcp\"|\1${WEB}:8443/tcp\"|" \
    -e "s|^\( *- \"\)[0-9]*:3478/tcp\"|\1${TURN}:3478/tcp\"|" \
    -e "s|^\( *- \"\)[0-9]*:3478/udp\"|\1${TURN}:3478/udp\"|" \
    -e "s|^\( *- \"\)[0-9]*-[0-9]*:[0-9]*-[0-9]*/udp\"|\1${RMIN}-${RMAX}:${RMIN}-${RMAX}/udp\"|" \
    -e "s|^\( *- EXTERNAL_SIGNALING_PORT=\).*|\1${WEB}|" \
    -e "s|^\( *- EXTERNAL_TURN_PORT=\).*|\1${TURN}|" \
    -e "s|^\( *- COTURN_MIN_PORT=\).*|\1${RMIN}|" \
    -e "s|^\( *- COTURN_MAX_PORT=\).*|\1${RMAX}|" \
    "$COMPOSE"

echo "apply_ports: 画面=${WEB} TURN=${TURN} 中继=${RMIN}-${RMAX}（容器内固定 8443/3478/${RMIN}-${RMAX}）"

### 同步 manifest 的 service_port（关键）：飞牛统一网关按 manifest 的 service_port 反代，
### 不同步的话，改了画面端口会出现「应用中心打不开 / 直连新端口也不通」的假故障。
MANIFEST="$(dirname "$APP_DIR")/manifest"
if [ -f "$MANIFEST" ]; then
    _cur=$(sed -n 's/^service_port[[:space:]]*=[[:space:]]*//p' "$MANIFEST" | head -n1 | tr -d ' ')
    if [ -n "$_cur" ] && [ "$_cur" != "$WEB" ]; then
        sed -i "s|^service_port[[:space:]]*=.*|service_port               = ${WEB}|" "$MANIFEST"
        echo "apply_ports: manifest service_port ${_cur} → ${WEB}（若应用中心入口未立即生效，停用后启用一次本应用）"
    fi
fi

### 同步到 /docker（飞牛 docker-project 读取该路径）
mkdir -p /docker 2>/dev/null || true
cp -f "$COMPOSE" /docker/docker-compose.yaml 2>/dev/null || true
chmod 644 /docker/docker-compose.yaml 2>/dev/null || true

[ "$NO_RESTART" = "1" ] && { echo "apply_ports: --no-restart，仅写配置"; exit 0; }

### 重建容器让端口映射生效（数据卷不变）
if docker inspect cloudphone-webrtc >/dev/null 2>&1; then
    ( cd "$APP_DIR/docker" 2>/dev/null && docker compose -p cloudphone up -d --force-recreate webrtc ) >/dev/null 2>&1 \
        && echo "apply_ports: 画面服务已按新端口重建" \
        || echo "apply_ports: 重建失败（可在应用中心重启应用后生效）"
else
    echo "apply_ports: 容器尚未创建，配置已就绪"
fi

exit 0
