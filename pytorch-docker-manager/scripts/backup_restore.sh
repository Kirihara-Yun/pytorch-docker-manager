#!/bin/bash
# 独立的容器备份恢复脚本（主脚本已集成，可单独使用）

set -euo pipefail

BACKUP_DIR="./backup"
LOG_FILE="./logs/backup_restore.log"

log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "${LOG_FILE}"
}

# 备份
backup_container() {
    local container_name=$1
    if [ -z "${container_name}" ]; then
        echo "用法：$0 backup <容器名称>"
        exit 1
    fi

    mkdir -p "${BACKUP_DIR}" "${LOG_FILE%/*}"
    local backup_name="${container_name}_$(date +%Y%m%d_%H%M%S)"

    log "开始备份容器${container_name}"
    docker stop "${container_name}" >/dev/null 2>&1 || true
    docker commit "${container_name}" "${container_name}_backup:${backup_name}"
    docker save -o "${BACKUP_DIR}/${backup_name}.tar" "${container_name}_backup:${backup_name}"
    tar -zcf "${BACKUP_DIR}/${backup_name}_data.tar.gz" "${HOME}/pytorch-prod/data"
    docker start "${container_name}" >/dev/null 2>&1 || true

    echo "备份完成：${BACKUP_DIR}/${backup_name}.tar"
}

# 恢复
restore_container() {
    local backup_file=$1
    if [ -z "${backup_file}" ] || [ ! -f "${backup_file}" ]; then
        echo "用法：$0 restore <备份文件.tar>"
        exit 1
    fi

    mkdir -p "${LOG_FILE%/*}"
    local container_name=$(basename "${backup_file}" | cut -d'_' -f1)
    local data_backup=$(echo "${backup_file}" | sed 's/\.tar$/_data.tar.gz/')

    log "开始恢复容器${container_name} from ${backup_file}"
    docker load -i "${backup_file}"
    local image=$(docker images | grep "${container_name}_backup" | awk '{print $1":"$2}' | head -1)
    docker run -d --name "${container_name}" --gpus all -v "${HOME}/pytorch-prod/data:/app/data" "${image}" tail -f /dev/null

    if [ -f "${data_backup}" ]; then
        tar -zxf "${data_backup}" -C "${HOME}/pytorch-prod/data" --strip-components=1
    fi

    echo "恢复完成：容器${container_name}已启动"
}

case $1 in
    backup) backup_container "$2" ;;
    restore) restore_container "$2" ;;
    *) echo "用法：$0 [backup|restore] <参数>" ;;
esac