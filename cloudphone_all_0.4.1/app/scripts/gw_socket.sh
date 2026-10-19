#!/bin/bash
### gw_socket.sh — 网关入口兜底启动器（bash 原生 nohup + setsid）
###
### 什么时候用：`gateway.py start` 在应用中心安装/升级回调环境里可能因
### subprocess 无法拉起守护（实测 PermissionError(13)）而失败。本脚本用
### bash 原生方式拉起，不依赖 Python 的 Popen。
###
### 用法：
###   bash gw_socket.sh start     # 幂等：入口已健康则不动
###   bash gw_socket.sh stop
###   bash gw_socket.sh status

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/cloudphone/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/cloudphone/var}"
GW="$APP_DIR/server/gateway.py"
SOCK="$APP_DIR/app.sock"
LOG="$VAR_DIR/gateway.log"
PIDF="$VAR_DIR/gateway_bash.pid"

mkdir -p "$VAR_DIR" 2>/dev/null || true

healthy() { [ -S "$SOCK" ] && [ -f "$VAR_DIR/gateway.pid" ]; }

case "${1:-start}" in
    start)
        if healthy && kill -0 "$(cat "$VAR_DIR/gateway.pid" 2>/dev/null)" 2>/dev/null; then
            echo "gw_socket: 入口已就绪（$SOCK），无需启动"
            exit 0
        fi
        # 清理可能残留的旧守护，避免抢 socket
        if [ -f "$VAR_DIR/gateway.pid" ]; then
            kill "$(cat "$VAR_DIR/gateway.pid" 2>/dev/null)" 2>/dev/null || true
            sleep 1
        fi
        export TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR"
        ( setsid nohup /usr/bin/python3 "$GW" supervise >>"$LOG" 2>&1 < /dev/null & ) \
            || ( setsid nohup python3 "$GW" supervise >>"$LOG" 2>&1 < /dev/null & )
        # 等待 socket 出现（最多 15 秒）
        for _ in $(seq 1 15); do
            [ -S "$SOCK" ] && break
            sleep 1
        done
        if [ -S "$SOCK" ]; then
            echo "gw_socket: 入口已就绪：$SOCK → 127.0.0.1:8443"
            exit 0
        fi
        echo "gw_socket: 启动后 15 秒仍未出现 $SOCK，请查看 $LOG"
        exit 1
        ;;
    stop)
        if [ -f "$VAR_DIR/gateway.pid" ]; then
            kill "$(cat "$VAR_DIR/gateway.pid" 2>/dev/null)" 2>/dev/null || true
        fi
        if [ -f "$PIDF" ]; then
            kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null || true
            rm -f "$PIDF"
        fi
        echo "gw_socket: 已停止"
        ;;
    status)
        if [ -S "$SOCK" ]; then echo "入口: $SOCK（存在）"; else echo "入口: 不存在"; fi
        if [ -f "$VAR_DIR/gateway.pid" ]; then
            p=$(cat "$VAR_DIR/gateway.pid" 2>/dev/null)
            kill -0 "$p" 2>/dev/null && echo "守护: running (pid $p)" || echo "守护: not running"
        else
            echo "守护: not running"
        fi
        ;;
    *)
        echo "用法：$0 {start|stop|status}" >&2
        exit 1
        ;;
esac
