#!/bin/bash
set -e

# ==============================================================================
# 穿云投屏（ScrcpyOverWebRTC）容器入口脚本 —— cloudphone 定制版
#
# 与上游 entrypoint.sh 的差异：
#   1) 生成 turnserver.conf 时包含 listening-ip=0.0.0.0（上游缺失 → 只监听网桥，
#      局域网/外网都连不上 TURN）；
#   2) 服务进程降权到容器内 appuser 运行；
#   3) 向 /app/assets/index.html 注入少量前端修正脚本（幂等）：
#      · ICE/TURN 强制使用本机 TURN（信令不下发 ice_servers 时兜底）
#      · 自动隐藏上游 0.4.1 的「外网访问」提示框（无关闭按钮，遮挡画面）
#      · 移动端自适应样式 + 全屏处理（与飞牛网关侧保持一致）
# ==============================================================================

# 1. 读取并配置默认环境变量
PUBLIC_IP=${PUBLIC_IP:-"127.0.0.1"}
TURN_USER=${TURN_USER:-"cloudphone_user"}
TURN_PASSWORD=${TURN_PASSWORD:-"cloudphone_secure_password"}
SIGNALING_PORT=${SIGNALING_PORT:-8443}
USE_TLS=${USE_TLS:-true}
DEFAULT_SETTINGS=${DEFAULT_SETTINGS:-'{"maxBitrate":12,"minBitrate":4,"fps":60,"size":1280,"bitrate":16,"audio":true}'}

EXTERNAL_SIGNALING_PORT=${EXTERNAL_SIGNALING_PORT:-${SIGNALING_PORT}}
EXTERNAL_TURN_PORT=${EXTERNAL_TURN_PORT:-3478}

COTURN_MIN_PORT=${COTURN_MIN_PORT:-50000}
COTURN_MAX_PORT=${COTURN_MAX_PORT:-50100}

# PUBLIC_IP 兜底：容器内 hostname -I 只能看到容器 IP（对端不可达）。
# 正常情况下由 net_mode.sh / 安装向导写入宿主局域网 IP 或公网 IP。
if [ "$PUBLIC_IP" = "127.0.0.1" ]; then
    _detected_ip=""
    for _ip in $(hostname -I 2>/dev/null); do
        case "$_ip" in
            172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) [ -z "$_detected_ip" ] && _detected_ip="$_ip" ;;
            192.168.*|10.*) _detected_ip="$_ip"; break ;;
            *) [ -z "$_detected_ip" ] && _detected_ip="$_ip" ;;
        esac
    done
    if [ -n "$_detected_ip" ]; then
        PUBLIC_IP="$_detected_ip"
        echo "WARNING: PUBLIC_IP 未配置，回退为容器 IP: $PUBLIC_IP"
        echo "         （对端很可能不可达；请用 scripts/net_mode.sh 写入宿主 IP）"
    fi
fi

echo "========================================================"
echo "    穿云投屏 服务启动 (cloudphone)"
echo "========================================================"
echo "Public IP:          $PUBLIC_IP"
echo "Signaling Port:     $SIGNALING_PORT (对外: $EXTERNAL_SIGNALING_PORT)"
echo "TURN Port:          3478 (对外: $EXTERNAL_TURN_PORT)"
echo "TURN Username:      $TURN_USER"
echo "TURN UDP Ports:     $COTURN_MIN_PORT -> $COTURN_MAX_PORT"
echo "TLS Enabled:        $USE_TLS"
echo "========================================================"

# 2. 动态生成 coturn 配置文件（包含 listening-ip=0.0.0.0）
mkdir -p /etc/coturn
cat <<EOF > /etc/coturn/turnserver.conf
# 自动生成的 coturn 配置文件 (cloudphone custom)
listening-port=3478
listening-ip=0.0.0.0
fingerprint
lt-cred-mech
user=${TURN_USER}:${TURN_PASSWORD}
realm=cloudphone
external-ip=${PUBLIC_IP}
min-port=${COTURN_MIN_PORT}
max-port=${COTURN_MAX_PORT}
stale-nonce=600
no-multicast-peers
no-loopback-peers
no-cli
simple-log
syslog
verbose
bps-capacity=0
user-quota=0
total-quota=0
max-allocate-lifetime=3600
channel-lifetime=600
permission-lifetime=300
EOF

# 3. 创建非 root 用户并设置权限（服务降权运行）
APP_UID=${APP_UID:-1000}
APP_GID=${APP_GID:-1000}
if ! id appuser >/dev/null 2>&1; then
    addgroup -g "$APP_GID" appuser 2>/dev/null || true
    adduser -u "$APP_UID" -G appuser -s /bin/sh -D appuser 2>/dev/null || true
fi
chown -R appuser:appuser /etc/coturn /app/data 2>/dev/null || true
chmod 755 /etc/coturn /app/data 2>/dev/null || true
echo "Services will run as appuser (uid=$APP_UID, gid=$APP_GID)"

# 4. 启动 coturn（降权到 appuser）
echo "Starting coturn daemon (listening on 0.0.0.0, as appuser)..."
nice -n -10 su appuser -c "turnserver -c /etc/coturn/turnserver.conf" &
COTURN_PID=$!

# 5. 配置并透传环境变量给 webrtc-signaling
export PORT=${SIGNALING_PORT}
export HOST=0.0.0.0
export ASSETS=${ASSETS:-"/app/assets"}
export USE_TLS=${USE_TLS}
export TLS_CERT=/app/certs/server.crt
export TLS_KEY=/app/certs/server.key
export DEFAULT_SETTINGS=${DEFAULT_SETTINGS}
# 上游新增的设备注册密钥（若 compose 设置了 CLOUDPHONE_DEVICE_SECRET 则自动启用校验，
# Agent 端需以 -device-secret 携带相同密钥注册）
if [ -n "${CLOUDPHONE_DEVICE_SECRET:-}" ]; then
    export CLOUDPHONE_DEVICE_SECRET
fi

# ICE_SERVERS：给浏览器与手机（容器外）用，只能用 PUBLIC_IP。
# 容器内不跑安卓设备，因此不再需要服务名那一组地址。
export ICE_SERVERS="turn:${TURN_USER}:${TURN_PASSWORD}@${PUBLIC_IP}:${EXTERNAL_TURN_PORT}?transport=udp,turn:${TURN_USER}:${TURN_PASSWORD}@${PUBLIC_IP}:${EXTERNAL_TURN_PORT}?transport=tcp,stun:${PUBLIC_IP}:${EXTERNAL_TURN_PORT}"

if [ ! -e "${ASSETS}/agent" ]; then
    echo "assets/agent directory not found. Restoring built-in agent binaries..."
    mkdir -p "${ASSETS}"
    ln -s /app/agent_binaries "${ASSETS}/agent" 2>/dev/null || cp -r /app/agent_binaries "${ASSETS}/agent"
fi

INDEX_HTML="${ASSETS}/index.html"

# 6. 注入 ICE/TURN 配置：信令服务器未下发 ice_servers 时兜底，强制走本机 TURN。
#    端口与账号取自环境变量，用户改端口后仍然正确。
if [ -f "$INDEX_HTML" ] && ! grep -q "cloudphone-ice-config" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="cloudphone-ice-config">
(function(){
  try{
    var host = window.location.hostname;
    var iceServers = [
      {urls: "turn:" + host + ":%TURN_PORT%?transport=udp", username: "%TURN_USER%", credential: "%TURN_PASS%"},
      {urls: "turn:" + host + ":%TURN_PORT%?transport=tcp", username: "%TURN_USER%", credential: "%TURN_PASS%"},
      {urls: "stun:" + host + ":%TURN_PORT%"}
    ];
    var OrigPC = window.RTCPeerConnection || window.webkitRTCPeerConnection || window.mozRTCPeerConnection;
    if(OrigPC){
      window.RTCPeerConnection = function(config, constraints){
        config = config || {};
        config.iceServers = iceServers;
        return new OrigPC(config, constraints);
      };
      window.RTCPeerConnection.prototype = OrigPC.prototype;
      console.log("[cloudphone] ICE servers injected:", iceServers);
    }
  }catch(e){}
})();
</script>
INJECT_EOF
    sed -i "s|%TURN_PORT%|${EXTERNAL_TURN_PORT}|g; s|%TURN_USER%|${TURN_USER}|g; s|%TURN_PASS%|${TURN_PASSWORD}|g" "$INDEX_HTML" 2>/dev/null || true
    echo "已注入 ICE/TURN 配置 JS 到 ${INDEX_HTML}"
fi

# 7. 自动隐藏上游 0.4.1 的「外网访问」提示框（无关闭按钮，遮挡画面）
if [ -f "$INDEX_HTML" ] && ! grep -q "cloudphone-hide-wan-tip" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="cloudphone-hide-wan-tip">
(function(){
  var hiddenSet = {};
  function hideWanTip(){
    var els = document.querySelectorAll('body *');
    for(var i=0;i<els.length;i++){
      var el = els[i];
      if(el.children.length===0 && el.textContent && el.textContent.trim().indexOf('外网访问')===0){
        var p = el;
        for(var j=0;j<6 && p.parentElement;j++){
          p = p.parentElement;
          var s = getComputedStyle(p);
          if((s.position==='fixed'||s.position==='absolute') && p.textContent.indexOf('外网访问')!==-1){
            var key = p.textContent.substring(0,30);
            if(!hiddenSet[key]){
              hiddenSet[key] = true;
              /* 先显示 3 秒，再淡出自动关闭 */
              p.style.transition = 'opacity 0.5s ease';
              setTimeout(function(){
                p.style.opacity = '0';
                setTimeout(function(){ p.style.display='none'; }, 500);
              }, 3000);
            }
            break;
          }
        }
      }
    }
  }
  hideWanTip();
  if(window.MutationObserver){
    new MutationObserver(hideWanTip).observe(document.body,{childList:true,subtree:true});
  } else {
    setInterval(hideWanTip, 1000);
  }
})();
</script>
INJECT_EOF
    echo "已注入隐藏外网提示框 JS 到 ${INDEX_HTML}"
fi

# 8. UI 一致性：移动端自适应样式 + 全屏处理。
#    飞牛统一网关侧也会注入同一份样式；下沉到页面本身后，
#    「走网关」与「直连端口」两条入口的界面完全一致。
if [ -f "$INDEX_HTML" ] && ! grep -q "cloudphone-ui-parity" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="cloudphone-ui-parity">
(function(){
  try{
    var css = "@media(max-width:768px){body,html{overflow-x:auto!important;-webkit-overflow-scrolling:touch!important;}"
      + "div[style*='position:fixed'][style*='bottom'],div[class*='bottom-panel'],div[class*='terminal-panel'],div[class*='tool-panel'],div[class*='drawer']{max-width:100vw!important;overflow-x:auto!important;overflow-y:hidden!important;}"
      + "div[class*='window'],div[class*='modal'],div[class*='dialog']{max-width:100vw!important;left:0!important;right:auto!important;}"
      + "button[class*='close'],button[aria-label*='close'],button[title*='关闭']{position:sticky!important;left:0!important;z-index:9999!important;}"
      + ".web-fullscreen .share-header,.web-fullscreen .conn-meta,.web-fullscreen .top-bar,.web-fullscreen .header{display:none!important;}"
      + ".web-fullscreen .share-main,.web-fullscreen .main{height:100vh!important;margin:0!important;padding:0!important;}"
      + ".web-fullscreen .share-page-container,.web-fullscreen .page-container{background:#000!important;margin:0!important;padding:0!important;}"
      + ".web-fullscreen .share-aside,.web-fullscreen .share-sidebar,.web-fullscreen .side-control,.web-fullscreen .control-bar,.web-fullscreen .action-bar,.web-fullscreen .tool-bar,.web-fullscreen .right-panel,.web-fullscreen .left-panel,.web-fullscreen .panel{display:none!important;}"
      + ".web-fullscreen .video-container,.web-fullscreen .screen-container,.web-fullscreen .player-container,.web-fullscreen .video-wrap,.web-fullscreen .screen-wrap,.web-fullscreen .player-wrap,.web-fullscreen .display-container{width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;max-width:100vw!important;max-height:100vh!important;}"
      + ".web-fullscreen .share-content,.web-fullscreen .main-content,.web-fullscreen .content-wrap,.web-fullscreen .content{width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;}"
      + ".web-fullscreen{margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;}"
      + "@media(min-width:768px){.web-fullscreen video,.web-fullscreen canvas,.web-fullscreen img{object-fit:contain!important;width:100%!important;height:100%!important;max-width:100vw!important;max-height:100vh!important;}}"
      + "@media(max-width:767px){.web-fullscreen video,.web-fullscreen canvas,.web-fullscreen img{object-fit:cover!important;width:100vw!important;height:100vh!important;}}"
      + ".gw-fs-active ._gw_hidden{display:none!important;}"
      + ".gw-fs-active body{margin:0!important;padding:0!important;overflow:hidden!important;}";
    var st = document.createElement("style");
    st.id = "cloudphone-ui-parity-style";
    st.textContent = css;
    (document.head||document.documentElement).appendChild(st);
    var hidden=[];
    function isMedia(e){return e.tagName&&(e.tagName==="VIDEO"||e.tagName==="CANVAS"||e.tagName==="IMG");}
    function hasMedia(e){if(isMedia(e))return true;for(var i=0;i<e.children.length;i++){if(hasMedia(e.children[i]))return true;}return false;}
    function enterFs(){hidden=[];var all=document.querySelectorAll("body *");for(var i=0;i<all.length;i++){var el=all[i];var cs=getComputedStyle(el);if((cs.position==="fixed"||cs.position==="sticky")&&!hasMedia(el)){el.classList.add("_gw_hidden");hidden.push(el);}}document.documentElement.classList.add("gw-fs-active");}
    function exitFs(){for(var i=0;i<hidden.length;i++){hidden[i].classList.remove("_gw_hidden");}hidden=[];document.documentElement.classList.remove("gw-fs-active");}
    document.addEventListener("fullscreenchange",function(){if(document.fullscreenElement){enterFs();}else{exitFs();}});
    document.addEventListener("webkitfullscreenchange",function(){if(document.webkitFullscreenElement){enterFs();}else{exitFs();}});
  }catch(e){}
})();
</script>
INJECT_EOF
    echo "已注入 UI 一致性样式/全屏处理 JS 到 ${INDEX_HTML}"
fi

# 9. 启动 webrtc-signaling（降权到 appuser）
echo "Starting webrtc-signaling server (as appuser, env inherited from export)..."
nice -n -10 su appuser -c "/app/webrtc-signaling" &
SIGNALING_PID=$!

sleep 1
echo ""
echo "========================================================"
echo "          穿云投屏 容器服务已成功启动！"
echo "========================================================"
echo " TURN listening on 0.0.0.0:3478 (all interfaces)"
echo " 浏览器访问：$([ "$USE_TLS" = "true" ] && echo "https" || echo "http")://<NAS_IP>:${EXTERNAL_SIGNALING_PORT}"
echo " 默认账号：admin / admin123（请登录后立即修改）"
echo "========================================================"
echo ""

# 10. 信号捕获与优雅退出
cleanup_processes() {
    echo "Stopping all services gracefully..."
    kill -TERM "$COTURN_PID" "$SIGNALING_PID" 2>/dev/null || true
    wait "$COTURN_PID" 2>/dev/null || true
    wait "$SIGNALING_PID" 2>/dev/null || true
    echo "Services stopped successfully."
}

trap cleanup_processes SIGINT SIGTERM

# 11. 等待任一关键进程退出
wait -n

echo "One of the services terminated unexpectedly!"
cleanup_processes
exit 1
