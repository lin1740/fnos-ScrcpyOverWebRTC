#!/bin/bash
### net_util.sh — 网络工具函数（供其它脚本 source）
###
### cp_lan_ip — 取「浏览器与手机都能访问到」的宿主局域网 IP。
###
### 为什么不能用 `hostname -I | awk '{print $1}'`：
###   宿主上有多个地址（docker 网桥 172.17/172.18、cni0、zfs 等），第一个未必是局域网 IP。
###   实测安装回调里取到了 172.18.0.1（docker 网桥网关），写进 PUBLIC_IP 后
###   coturn 的 external-ip 与 ICE 候选都不可达，表现为「面板能打开但设备连不上/黑屏」。
###
### 取值顺序：
###   1) 默认路由的源地址（`ip route get`）—— 这是对外通信真正用的那个地址，最可靠；
###   2) 枚举本机地址：优先非 172.16-31（避免 docker 网桥），排除回环/链路本地；
###   3) 全都没有时回退 127.0.0.1（并让上游日志给出明确警告）。

cp_lan_ip(){
    local ip cand fallback=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
             | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
        case "$ip" in
            ""|127.*|169.254.*|0.0.0.0) : ;;
            *) printf '%s' "$ip"; return 0 ;;
        esac
    fi
    for cand in $(hostname -I 2>/dev/null); do
        case "$cand" in
            127.*|169.254.*|0.0.0.0) continue ;;
            172.1[6-9].*|172.2[0-9].*|172.3[01].*) fallback="${fallback:-$cand}"; continue ;;
            *) printf '%s' "$cand"; return 0 ;;
        esac
    done
    printf '%s' "${fallback:-127.0.0.1}"
}
