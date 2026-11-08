#!/bin/bash
### set_ports.sh — 安装后调整本应用的对外端口
###
### 用法：
###   bash set_ports.sh --show                                  # 查看当前端口
###   bash set_ports.sh --web 9443                              # 改画面/信令对外端口
###   bash set_ports.sh --turn 3479                             # 改 TURN 对外端口
###   bash set_ports.sh --relay 51000-51100                     # 改媒体中继段
###   bash set_ports.sh --web 9443 --no-restart                 # 只写配置，稍后生效
###
### 说明（重要）：
###   · 容器内实际监听端口固定（画面 8443、TURN 3478），本脚本改的是
###     「宿主对外映射端口」与「对外通告值」；改完请在路由器 / 穿透工具同步映射。
###   · 中继段是例外：coturn 不支持端口转换，容器内外必须一致，
###     因此改中继段会同时改容器内 COTURN_MIN/MAX_PORT 与端口映射。
###   · 幂等：值没变化时不做多余动作；所有改动只落在应用数据目录的 ports.conf。
###   · 不改动容器数据卷（账号与设备绑定不受影响）。

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/cloudphone/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/cloudphone/var}"
CONF="$VAR_DIR/ports.conf"
mkdir -p "$VAR_DIR" 2>/dev/null || true

cur(){ sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1; }

SHOW=0; NO_RESTART=0; NEW_WEB=""; NEW_TURN=""; NEW_RELAY=""; NEW_EXT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --show)       SHOW=1; shift ;;
        --no-restart) NO_RESTART=1; shift ;;
        --web)        NEW_WEB="${2:-}"; shift 2 ;;
        --turn)       NEW_TURN="${2:-}"; shift 2 ;;
        --relay)      NEW_RELAY="${2:-}"; shift 2 ;;
        --ext)        NEW_EXT="${2:-}"; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：$1（可用：--show / --web N / --turn N / --relay MIN-MAX / --ext N / --no-restart）" >&2; exit 1 ;;
    esac
done

WEB="$(cur WEB_PORT)";   [ -n "$WEB" ]   || WEB=8443
TURN="$(cur TURN_PORT)"; [ -n "$TURN" ]  || TURN=3478
RMIN="$(cur RELAY_MIN)"; [ -n "$RMIN" ]  || RMIN=50000
RMAX="$(cur RELAY_MAX)"; [ -n "$RMAX" ]  || RMAX=50029
# 旧默认段自动迁移（与 apply_ports.sh 一致）：50000-50100 视为未定制 → 50000-50029
if [ -z "${CLOUDPHONE_RELAY_MIN:-}" ] && [ -z "${CLOUDPHONE_RELAY_MAX:-}" ] && [ "$RMIN" = "50000" ] && [ "$RMAX" = "50100" ]; then
    RMAX=50029
fi
EXT="$(cur EXT_PORT)"

if [ "$SHOW" = "1" ]; then
    echo "配置文件            : $CONF"
    echo "画面/信令对外端口   : WEB_PORT=${WEB}"
    echo "TURN 对外端口       : TURN_PORT=${TURN}"
    echo "媒体中继端口段      : RELAY_MIN-RELAY_MAX=${RMIN}-${RMAX}"
    echo "单独指定的对外端口  : EXT_PORT=${EXT:-（未设置，默认与画面端口一致）}"
    echo "容器内实际监听      : 画面 8443 / TURN 3478（固定，不随本项变化）"
    exit 0
fi

[ -n "$NEW_WEB" ]   && WEB="$NEW_WEB"
[ -n "$NEW_TURN" ]  && TURN="$NEW_TURN"
[ -n "$NEW_EXT" ]   && EXT="$NEW_EXT"

for v in "$WEB" "$TURN"; do
    case "$v" in ''|*[!0-9]*) echo "端口必须是数字：$v" >&2; exit 1 ;; esac
    [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || { echo "端口超出范围：$v" >&2; exit 1; }
done
if [ -n "$EXT" ]; then
    case "$EXT" in *[!0-9]*) echo "对外端口必须是数字：$EXT" >&2; exit 1 ;; esac
fi

if [ -n "$NEW_RELAY" ]; then
    case "$NEW_RELAY" in
        *-*) RMIN="${NEW_RELAY%%-*}"; RMAX="${NEW_RELAY##*-}" ;;
        *)   echo "中继段格式应为 MIN-MAX（如 50000-50029）：$NEW_RELAY" >&2; exit 1 ;;
    esac
    for v in "$RMIN" "$RMAX"; do
        case "$v" in ''|*[!0-9]*) echo "中继段必须是数字：$NEW_RELAY" >&2; exit 1 ;; esac
        [ "$v" -ge 1024 ] && [ "$v" -le 65535 ] || { echo "中继段端口超出范围：$v" >&2; exit 1; }
    done
    [ "$RMIN" -le "$RMAX" ] || { echo "中继段起点必须小于终点：$NEW_RELAY" >&2; exit 1; }
    [ $((RMAX - RMIN)) -le 500 ] || { echo "中继段跨度不宜超过 500 个端口：$NEW_RELAY" >&2; exit 1; }
fi

{
    echo "WEB_PORT=$WEB"
    echo "TURN_PORT=$TURN"
    echo "RELAY_MIN=$RMIN"
    echo "RELAY_MAX=$RMAX"
    [ -n "$EXT" ] && echo "EXT_PORT=$EXT"
    echo "UPDATED=$(date '+%F %T')"
} > "$CONF" 2>/dev/null || { echo "无法写入 $CONF" >&2; exit 1; }
echo "已更新端口：画面=$WEB  TURN对外=$TURN  中继=$RMIN-$RMAX${EXT:+  对外=$EXT}"

if [ "$NO_RESTART" = "1" ]; then
    echo "（--no-restart）仅写入配置，稍后由相关服务读取生效"
    exit 0
fi

### 占用预检：中继段只要有一个被占，Docker 整段绑定就会失败
if [ -f "$APP_DIR/scripts/apply_ports.sh" ]; then
    if ! bash "$APP_DIR/scripts/apply_ports.sh" --check; then
        echo "警告：检测到端口占用（见上）。容器可能无法启动，请换一段端口后重试。" >&2
    fi
    if bash "$APP_DIR/scripts/apply_ports.sh" >/dev/null 2>&1; then
        echo "画面服务已按新端口重建（数据卷不变）"
    else
        echo "画面服务重建未成功，可在应用中心「重启应用」后生效"
    fi
fi

echo "提示：如在路由器 / 穿透工具中做过端口映射，请同步改为新端口。"
exit 0
