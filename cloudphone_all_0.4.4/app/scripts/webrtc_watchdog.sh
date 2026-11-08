#!/bin/bash
### webrtc_watchdog.sh — 画面服务容器看护
###
### 职责（只做三件事，不碰数据卷）：
###   1) 容器不存在        → 用 compose 拉起
###   2) 容器存在但未运行  → docker start
###   3) 容器在跑但端口不通（连续 3 次）→ docker restart
### 限流：每小时最多自动重启 3 次，避免异常时无限重启。
###
### 用法：
###   webrtc_watchdog.sh install    # 后台常驻（写 PID 文件）
###   webrtc_watchdog.sh remove     # 停止
###   webrtc_watchdog.sh status     # 查看
###   webrtc_watchdog.sh once       # 只检查一次（排障用）

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/cloudphone/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/cloudphone/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
PIDF="$VAR_DIR/webrtc_watchdog.pid"
LOGF="$VAR_DIR/webrtc_watchdog.log"
C="cloudphone-webrtc"
INTERVAL="${WATCHDOG_INTERVAL:-30}"

mkdir -p "$VAR_DIR" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" >> "$LOGF"; }

port_ok(){
    local p="${1:-8443}"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1
    fi
}

web_port(){
    local v
    v=$(sed -n 's/^WEB_PORT=//p' "$VAR_DIR/ports.conf" 2>/dev/null | head -n1)
    case "$v" in ''|*[!0-9]*) v=8443 ;; esac
    printf '%s' "$v"
}

### 0.4.1-2：停用不再复活容器。
### 实测飞牛「停用」只执行 compose stop，从不调用 cmd/main stop（停用期间无 main.log、
### 无 cmd/main 进程），旧看护仍在，15~30 秒内就用 docker start 把容器拉回来，
### 「停用」形同虚设。现在区分两种「容器不在跑」：
###   · exited/dead（存在但已停）= 用户停用 → 不再自动 start；真正的进程崩溃由 compose
###     的 restart: unless-stopped 负责重启，不依赖看护。
###   · created/restarting/paused = 正在启动/重启 → 只观察，不介入。
### 连续 WATCHDOG_DOWN_MAX（默认 300s）未运行 → 判定停用：停网关、进入休眠，
### 但看护自身保留（飞牛「启用」只做 compose up，不会调用 cmd/main start，
### 没有看护就没有进程把网关拉回来）。
DIS_SINCE="$VAR_DIR/.app_down_since"
DORMANT_FLAG="$VAR_DIR/.app_dormant"

down_secs(){
    local now s
    now=$(date +%s 2>/dev/null || echo 0)
    s=$(cat "$DIS_SINCE" 2>/dev/null)
    case "$s" in
        ''|*[!0-9]*) echo "$now" > "$DIS_SINCE" 2>/dev/null || true; echo 0 ;;
        *) echo $(( now - s )) ;;
    esac
}

check_once(){
    local p; p="$(web_port)"
    local st running
    st=$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null | head -n1 | tr -d '\r\n')
    running=$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | head -n1 | tr -d '\r\n')

    ### A) 容器存在但未运行：不自动拉起（见上方说明）
    if [ -n "$st" ] && [ "$running" != "true" ]; then
        case "$st" in
            created|restarting|paused)
                ### 正在启动/重启：清掉停用计时，等它自己起来
                rm -f "$DIS_SINCE" "$DORMANT_FLAG" 2>/dev/null || true
                return
                ;;
        esac
        local d
        d=$(down_secs)
        local max_down="${WATCHDOG_DOWN_MAX:-300}"
        if [ "$d" -ge "$max_down" ]; then
            if [ ! -f "$DORMANT_FLAG" ]; then
                : > "$DORMANT_FLAG" 2>/dev/null || true
                log "容器已停止 ${d}s → 判定应用被停用：休眠，不再拉起容器，并停止网关（启用后自动恢复）"
                if [ -f "$APP_DIR/server/gateway.py" ]; then
                    env TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                        python3 "$APP_DIR/server/gateway.py" stop >/dev/null 2>&1 || true
                fi
            fi
        elif [ "$d" -lt 60 ]; then
            log "容器已停止 ${d}s（用户停用中，看护不自动拉起；崩溃重启由 compose restart 策略负责）"
        fi
        return
    fi

    ### 运行中：解除休眠
    rm -f "$DIS_SINCE" "$DORMANT_FLAG" 2>/dev/null || true

    ### B) 容器不存在（只有卸载后重装 / 首次安装失败才会出现）→ 用 compose 拉起
    if [ -z "$st" ]; then
        log "容器不存在，尝试用 compose 拉起"
        # compose 引用本地稳定 tag（cloudphone-cache/webrtc:pinned），镜像缺失时先补
        if ! docker image inspect "${PINNED_WEBRTC:-cloudphone-cache/webrtc:pinned}" >/dev/null 2>&1; then
            [ -f "$APP_DIR/scripts/pull_image.sh" ] && bash "$APP_DIR/scripts/pull_image.sh" >>"$LOGF" 2>&1 || true
        fi
        ( cd "$APP_DIR/docker" 2>/dev/null && timeout 300 docker compose -p cloudphone up -d webrtc ) >/dev/null 2>&1 \
            && log "已拉起" || log "拉起失败（compose 不可用？）"
        return
    fi

    ### C) 运行中：网关入口兜底（socket 缺失或守护不在时拉起，保证应用中心入口可用）。
    ### 实测：安装回调环境里 gateway.py start 可能因 Popen EACCES 失败，
    ### 这里是最后一道保险（每轮最多尝试一次）。
    if [ -f "$APP_DIR/server/gateway.py" ]; then
        local gwdead=1
        if [ -f "$VAR_DIR/gateway.pid" ] && kill -0 "$(cat "$VAR_DIR/gateway.pid" 2>/dev/null)" 2>/dev/null; then
            gwdead=0
        fi
        if [ "$gwdead" = "1" ] || [ ! -S "$APP_DIR/app.sock" ]; then
            log "网关入口缺失/守护不在，执行 gateway.py start"
            env TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                python3 "$APP_DIR/server/gateway.py" start >/dev/null 2>&1 || true
            if [ ! -S "$APP_DIR/app.sock" ] && [ -f "$APP_DIR/scripts/gw_socket.sh" ]; then
                log "入口仍未就绪，用 gw_socket.sh 兜底"
                env TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                    bash "$APP_DIR/scripts/gw_socket.sh" start >>"$LOGF" 2>&1 || true
            fi
        fi
    fi

    if ! port_ok "$p"; then
        local n
        n=$(cat "$VAR_DIR/webrtc_portfail.count" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$VAR_DIR/webrtc_portfail.count" 2>/dev/null || true
        log "端口 $p 未监听（连续第 $n 次）"
        if [ "$n" -ge 3 ]; then
            local r
            r=$(cat "$VAR_DIR/webrtc_restart.count" 2>/dev/null || echo 0)
            if [ "$r" -lt 3 ]; then
                log "连续 3 次端口不通，重启容器（本小时第 $((r + 1)) 次）"
                docker restart "$C" >/dev/null 2>&1 && log "已重启" || log "重启失败"
                echo "$((r + 1))" > "$VAR_DIR/webrtc_restart.count" 2>/dev/null || true
            else
                log "已达每小时重启上限（3 次），停止自动重启；请检查 docker logs $C"
            fi
            echo 0 > "$VAR_DIR/webrtc_portfail.count" 2>/dev/null || true
        fi
    else
        echo 0 > "$VAR_DIR/webrtc_portfail.count" 2>/dev/null || true
        echo 0 > "$VAR_DIR/webrtc_restart.count" 2>/dev/null || true
    fi
}

case "${1:-once}" in
    install)
        if [ -f "$PIDF" ]; then
            pid=$(cat "$PIDF" 2>/dev/null)
            [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null && { echo "已在运行（pid=$pid）"; exit 0; }
        fi
        (
            while true; do
                check_once
                sleep "$INTERVAL"
            done
        ) >/dev/null 2>&1 &
        echo $! > "$PIDF"
        echo "webrtc_watchdog 已启动（pid=$(cat "$PIDF")，间隔 ${INTERVAL}s）"
        ;;
    remove)
        if [ -f "$PIDF" ]; then
            pid=$(cat "$PIDF" 2>/dev/null)
            [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
            rm -f "$PIDF"
            echo "webrtc_watchdog 已停止"
        else
            echo "webrtc_watchdog 未在运行"
        fi
        ;;
    status)
        if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
            echo "运行中（pid=$(cat "$PIDF")）"
        else
            echo "未运行"
        fi
        echo "容器状态：$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo '不存在')"
        echo "画面端口：$(web_port) $([ "$(port_ok "$(web_port)")" ] && echo 已监听 || echo 未监听)"
        [ -f "$LOGF" ] && { echo "--- 最近日志 ---"; tail -n 10 "$LOGF"; }
        ;;
    once)
        check_once
        echo "检查完成"
        ;;
    *)
        echo "用法：$0 {install|remove|status|once}" >&2
        exit 1
        ;;
esac
exit 0
