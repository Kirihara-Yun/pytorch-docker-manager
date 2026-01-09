#!/bin/bash
# 容器健康检查脚本：定时检查容器状态，异常自动重启

set -euo pipefail

CONTAINER_NAME=$1
CHECK_INTERVAL=${2:-60}
RESTART_THRESHOLD=${3:-3}
RESTART_COUNT=0
LOG_FILE="${BASE_DIR:-$(cd $(dirname $0)/.. && pwd)}/logs/health_check.log"

# 日志函数
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "${LOG_FILE}"
}

log "启动容器${CONTAINER_NAME}健康检查（间隔${CHECK_INTERVAL}秒）"

while true; do
    # 检查容器是否运行
    if ! docker ps | grep -q "${CONTAINER_NAME}"; then
        RESTART_COUNT=$((RESTART_COUNT + 1))
        log "容器${CONTAINER_NAME}未运行（重启次数：${RESTART_COUNT}/${RESTART_THRESHOLD}）"

        # 达到阈值则停止检查
        if [ ${RESTART_COUNT} -ge ${RESTART_THRESHOLD} ]; then
            log "容器重启次数达到阈值，停止健康检查"
            exit 1
        fi

        # 尝试重启容器
        log "尝试重启容器${CONTAINER_NAME}"
        docker start "${CONTAINER_NAME}" || log "容器重启失败！"
    else
        # 重置重启计数
        RESTART_COUNT=0
    fi

    sleep ${CHECK_INTERVAL}
done