#!/bin/bash
### rtconf.sh — 统一加载「运行时版本配置」（单一可信源）
###
### 目的：镜像名/标签只在一处维护（app/docker/runtime.conf），其它脚本一律从这里取。
###
### 用法：
###   . /path/to/rtconf.sh   然后调用 rtconf_load        # 在脚本里（推荐）
###   bash rtconf.sh show                                # 打印当前生效值
###
### 查找顺序：$CLOUDPHONE_RUNTIME_CONF → $TRIM_APPDEST/docker/runtime.conf →
###           与本脚本同级的 ../docker/runtime.conf

rtconf_file(){
    for _c in "${CLOUDPHONE_RUNTIME_CONF:-}" \
              "${TRIM_APPDEST:-/var/apps/cloudphone/target}/docker/runtime.conf" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" 2>/dev/null && pwd)/runtime.conf"; do
        [ -n "${_c:-}" ] && [ -f "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    return 1
}

rtconf_load(){
    _rt_f="$(rtconf_file)" || _rt_f=""
    if [ -n "$_rt_f" ]; then
        # shellcheck disable=SC1090
        . "$_rt_f"
    else
        # 兜底默认（与 app/docker/runtime.conf 完全一致）
        APP_NAME="${CLOUDPHONE_APP_NAME:-cloudphone}"
        WEBRTC_REPO="${CLOUDPHONE_WEBRTC_REPO:-buutuu/scrcpy-over-webrtc}"
        WEBRTC_TAG="${CLOUDPHONE_WEBRTC_TAG:-latest}"
        ACCEL_PREFIX="${CLOUDPHONE_ACCEL_PREFIX:-docker.fnnas.com}"
        CACHE_PREFIX="${CLOUDPHONE_CACHE_PREFIX:-cloudphone-cache}"
        WEBRTC_PIN="${CLOUDPHONE_WEBRTC_PIN:-1}"
        WEBRTC_DIGEST="${CLOUDPHONE_WEBRTC_DIGEST:-}"
    fi
    ### 派生值兜底（配置文件被裁剪掉派生段也不会空）
    : "${APP_NAME:=cloudphone}"
    : "${WEBRTC_REPO:=buutuu/scrcpy-over-webrtc}"
    : "${WEBRTC_TAG:=latest}"
    : "${ACCEL_PREFIX:=docker.fnnas.com}"
    : "${CACHE_PREFIX:=cloudphone-cache}"
    : "${WEBRTC_PIN:=1}"
    : "${CANON_WEBRTC:=${ACCEL_PREFIX}/${WEBRTC_REPO}:${WEBRTC_TAG}}"
    : "${OFF_WEBRTC:=${WEBRTC_REPO}:${WEBRTC_TAG}}"
    : "${CACHE_WEBRTC:=${CACHE_PREFIX}/webrtc:${WEBRTC_TAG}}"
    export APP_NAME WEBRTC_REPO WEBRTC_TAG ACCEL_PREFIX CACHE_PREFIX WEBRTC_PIN WEBRTC_DIGEST \
           CANON_WEBRTC OFF_WEBRTC CACHE_WEBRTC
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-show}" in
        show|"")
            rtconf_load
            echo "配置来源       : $(rtconf_file || echo '（未找到 runtime.conf，使用内置默认）')"
            echo "应用标识       : $APP_NAME"
            echo "版本策略       : $([ "${WEBRTC_PIN:-1}" = "1" ] && echo "钉死 digest ${WEBRTC_DIGEST:-（未设置）}" || echo "跟随 :latest")"
            echo "穿云投屏镜像   : $CANON_WEBRTC   （别名 $OFF_WEBRTC）"
            echo "升级缓存标签   : $CACHE_WEBRTC"
            ;;
        *) echo "用法：$0 [show]"; exit 1 ;;
    esac
fi
