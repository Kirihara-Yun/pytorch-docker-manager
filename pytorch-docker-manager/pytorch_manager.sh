#!/bin/bash
# PyTorch Docker环境全生命周期管理工具
# 支持多环境配置、资源限制、健康检查、日志持久化、备份恢复等功能
# 适用场景：PyTorch开发/生产环境快速部署与管理

set -euo pipefail

# ===================== 全局常量 =====================
TOOL_NAME="PyTorch Docker Manager"
TOOL_VERSION="1.0.0"
BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="${BASE_DIR}/config"
SCRIPTS_DIR="${BASE_DIR}/scripts"
LOG_DIR="${BASE_DIR}/logs"
DATA_DIR="${BASE_DIR}/data"
DEFAULT_ENV="dev"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 工具函数 =====================
# 打印日志（带级别）
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local log_file="${LOG_DIR}/manager.log"

    # 创建日志目录
    mkdir -p "${LOG_DIR}"

    case ${level} in
        INFO)
            echo -e "${GREEN}[INFO]${NC} [${timestamp}] ${msg}" | tee -a "${log_file}"
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} [${timestamp}] ${msg}" | tee -a "${log_file}"
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${NC} [${timestamp}] ${msg}" | tee -a "${log_file}" >&2
            ;;
        DEBUG)
            echo -e "${BLUE}[DEBUG]${NC} [${timestamp}] ${msg}" | tee -a "${log_file}"
            ;;
    esac
}

# 加载配置文件
load_config() {
    local env=$1
    local config_file="${CONFIG_DIR}/${env}.ini"

    # 检查配置文件是否存在
    if [ ! -f "${config_file}" ]; then
        log "ERROR" "环境配置文件不存在：${config_file}"
        log "ERROR" "可用环境：$(ls ${CONFIG_DIR} | grep -E '\.ini$' | sed 's/\.ini//g' | tr '\n' ' ')"
        exit 1
    fi

    log "INFO" "加载配置文件：${config_file}"

    # 解析配置文件（替换变量、去除注释）
    eval "$(grep -v '^#' "${config_file}" | grep -v '^$' | sed \
        -e 's/=/="/' \
        -e 's/$/"/' \
        -e 's/^/export /' \
        -e 's/${HOME}/'"${HOME}"'/g')"

    # 验证核心配置
    if [ -z "${CONTAINER_NAME}" ] || [ -z "${TORCH_IMAGE_TAG}" ]; then
        log "ERROR" "配置文件缺少核心参数（CONTAINER_NAME/TORCH_IMAGE_TAG）"
        exit 1
    fi

    # 初始化挂载目录
    mkdir -p "${CODE_HOST_DIR}" "${DATA_HOST_DIR}" "${LOG_HOST_DIR}"
}

# 版本兼容性检测
check_compatibility() {
    log "INFO" "开始版本兼容性检测..."

    # 检测Docker版本
    local docker_version=$(docker --version | awk '{print $3}' | cut -d',' -f1 | cut -d'.' -f1-2)
    if [ $(echo "${docker_version} < 20.10" | bc -l) -eq 1 ]; then
        log "WARN" "Docker版本过低（${docker_version}），建议升级至20.10+"
    fi

    # 检测nvidia-docker（GPU环境）
    if command -v nvidia-smi &> /dev/null; then
        if ! docker info | grep -q "nvidia"; then
            log "ERROR" "GPU环境检测失败：未安装nvidia-docker2"
            log "INFO" "安装指引：https://github.com/NVIDIA/nvidia-docker"
            exit 1
        fi
        # 检测CUDA版本匹配
        local host_cuda=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}' | cut -d'.' -f1-2)
        local image_cuda=$(echo "${TORCH_IMAGE_TAG}" | grep -oE 'cuda[0-9]+\.[0-9]+' | cut -d'a' -f2)
        if [ -n "${image_cuda}" ] && [ "${host_cuda}" != "${image_cuda}" ]; then
            log "WARN" "宿主机CUDA(${host_cuda})与镜像CUDA(${image_cuda})版本不匹配，可能导致GPU不可用"
        fi
    fi

    log "INFO" "版本兼容性检测完成"
}

# 构建Docker运行命令
build_docker_cmd() {
    local docker_cmd="docker run "

    # 运行模式（交互式/后台）
    if [ "${RUN_MODE}" = "interactive" ]; then
        docker_cmd+="-it "
    else
        docker_cmd+="-d --restart=on-failure:${RESTART_THRESHOLD:-3} "
    fi

    # 容器名称
    docker_cmd+="--name ${CONTAINER_NAME} "

    # 资源限制
    if [ "${CPU_LIMIT}" != "0" ]; then
        docker_cmd+="--cpus=${CPU_LIMIT} "
    fi
    if [ "${MEMORY_LIMIT}" != "0" ]; then
        docker_cmd+="--memory=${MEMORY_LIMIT} "
    fi

    # GPU支持
    if command -v nvidia-smi &> /dev/null; then
        docker_cmd+="--gpus all "
    fi

    # 端口映射
    if [ -n "${PORT_MAPPING}" ] && [ "${PORT_MAPPING}" != "[]" ]; then
        local ports=$(echo "${PORT_MAPPING}" | sed -e 's/\["//g' -e 's/"\]//g' -e 's/", "/ /g')
        for port in ${ports}; do
            docker_cmd+="-p ${port} "
        done
    fi

    # 目录挂载
    docker_cmd+="-v ${CODE_HOST_DIR}:${CODE_CONTAINER_DIR} "
    docker_cmd+="-v ${DATA_HOST_DIR}:${DATA_CONTAINER_DIR} "
    docker_cmd+="-v ${LOG_HOST_DIR}:${LOG_CONTAINER_DIR} "
    # 容器日志挂载（JSON格式，便于解析）
    docker_cmd+="--log-driver=json-file --log-opt max-size=100m --log-opt max-file=3 "

    # 镜像名称+启动命令
    docker_cmd+="pytorch/pytorch:${TORCH_IMAGE_TAG} "
    if [ "${RUN_MODE}" = "interactive" ]; then
        docker_cmd+="/bin/bash"
    else
        # 生产环境保持容器运行
        docker_cmd+="tail -f /dev/null"
    fi

    echo "${docker_cmd}"
}

# ===================== 核心命令 =====================
# 1. 部署环境（核心功能）
deploy() {
    local env=${1:-${DEFAULT_ENV}}
    log "INFO" "========== 开始部署${env}环境 =========="

    # 步骤1：加载配置
    load_config "${env}"

    # 步骤2：兼容性检测
    check_compatibility

    # 步骤3：检查Docker状态
    if ! systemctl is-active --quiet docker; then
        log "ERROR" "Docker服务未运行，请执行：systemctl start docker"
        exit 1
    fi

    # 步骤4：停止并删除已有容器
    if docker ps -a | grep -q "${CONTAINER_NAME}"; then
        log "WARN" "容器${CONTAINER_NAME}已存在，先停止并删除..."
        docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi

    # 步骤5：拉取镜像（不存在则拉取）
    local image="pytorch/pytorch:${TORCH_IMAGE_TAG}"
    if ! docker images | grep -q "${image}"; then
        log "INFO" "拉取镜像：${image}"
        docker pull "${image}"
    else
        log "INFO" "镜像${image}已存在，跳过拉取"
    fi

    # 步骤6：构建并执行Docker命令
    local docker_cmd=$(build_docker_cmd)
    log "DEBUG" "Docker运行命令：${docker_cmd}"
    log "INFO" "创建${env}环境容器：${CONTAINER_NAME}"
    eval "${docker_cmd}"

    # 步骤7：安装依赖
    log "INFO" "安装自定义依赖..."
    if [ -f "${REQUIREMENTS_FILE}" ]; then
        docker cp "${REQUIREMENTS_FILE}" "${CONTAINER_NAME}:${CODE_CONTAINER_DIR}/"
        docker exec "${CONTAINER_NAME}" bash -c "cd ${CODE_CONTAINER_DIR} && pip install -r requirements.txt -i ${PIP_SOURCE}"
    else
        log "WARN" "依赖文件${REQUIREMENTS_FILE}不存在，跳过依赖安装"
    fi

    # 步骤8：生产环境启动健康检查
    if [ "${RUN_MODE}" = "daemon" ]; then
        log "INFO" "启动容器健康检查（间隔${CHECK_INTERVAL:-60}秒）"
        nohup "${SCRIPTS_DIR}/health_check.sh" "${CONTAINER_NAME}" "${CHECK_INTERVAL:-60}" "${RESTART_THRESHOLD:-3}" > "${LOG_DIR}/health_check.log" 2>&1 &
    fi

    # 步骤9：验证环境
    log "INFO" "验证PyTorch环境..."
    docker exec "${CONTAINER_NAME}" bash -c "python -c \"import torch; print('PyTorch版本：', torch.__version__); print('CUDA可用：', torch.cuda.is_available())\""

    log "INFO" "========== ${env}环境部署完成 =========="
    log "INFO" "容器名称：${CONTAINER_NAME}"
    log "INFO" "代码目录：${CODE_HOST_DIR} ↔ ${CODE_CONTAINER_DIR}"
    log "INFO" "数据目录：${DATA_HOST_DIR} ↔ ${DATA_CONTAINER_DIR}"
    log "INFO" "日志目录：${LOG_HOST_DIR} ↔ ${LOG_CONTAINER_DIR}"
    if [ "${RUN_MODE}" = "interactive" ]; then
        log "INFO" "进入容器：./pytorch_manager.sh enter ${env}"
    else
        log "INFO" "进入容器：docker exec -it ${CONTAINER_NAME} /bin/bash"
        log "INFO" "健康检查日志：${LOG_DIR}/health_check.log"
    fi
}

# 2. 进入容器
enter() {
    local env=${1:-${DEFAULT_ENV}}
    load_config "${env}"

    if ! docker ps | grep -q "${CONTAINER_NAME}"; then
        log "ERROR" "容器${CONTAINER_NAME}未运行！先执行：./pytorch_manager.sh deploy ${env}"
        exit 1
    fi

    log "INFO" "进入容器${CONTAINER_NAME}（${env}环境）"
    docker exec -it "${CONTAINER_NAME}" /bin/bash
}

# 3. 启动/停止/重启容器
start() {
    local env=${1:-${DEFAULT_ENV}}
    load_config "${env}"

    log "INFO" "启动容器：${CONTAINER_NAME}"
    docker start "${CONTAINER_NAME}"
    log "INFO" "容器启动成功，状态：$(docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME})"
}

stop() {
    local env=${1:-${DEFAULT_ENV}}
    load_config "${env}"

    log "INFO" "停止容器：${CONTAINER_NAME}"
    docker stop "${CONTAINER_NAME}"
    log "INFO" "容器停止成功，状态：$(docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME})"
}

restart() {
    local env=${1:-${DEFAULT_ENV}}
    load_config "${env}"

    log "INFO" "重启容器：${CONTAINER_NAME}"
    docker restart "${CONTAINER_NAME}"
    log "INFO" "容器重启成功，状态：$(docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME})"
}

# 4. 备份/恢复容器
backup() {
    local env=${1:-${DEFAULT_ENV}}
    load_config "${env}"
    local backup_dir="${BASE_DIR}/backup"
    local backup_name="${CONTAINER_NAME}_$(date +%Y%m%d_%H%M%S)"
    local backup_path="${backup_dir}/${backup_name}"

    log "INFO" "开始备份容器：${CONTAINER_NAME}"

    # 创建备份目录
    mkdir -p "${backup_dir}"

    # 步骤1：停止容器（保证数据一致性）
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    # 步骤2：保存容器为镜像
    log "INFO" "保存容器镜像：${backup_path}.tar"
    docker commit "${CONTAINER_NAME}" "${CONTAINER_NAME}_backup:${backup_name}"
    docker save -o "${backup_path}.tar" "${CONTAINER_NAME}_backup:${backup_name}"

    # 步骤3：备份数据目录
    log "INFO" "备份数据目录：${DATA_HOST_DIR} → ${backup_path}_data.tar.gz"
    tar -zcf "${backup_path}_data.tar.gz" "${DATA_HOST_DIR}"

    # 步骤4：重启容器
    docker start "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    log "INFO" "备份完成！备份文件："
    log "INFO" "  - 镜像备份：${backup_path}.tar"
    log "INFO" "  - 数据备份：${backup_path}_data.tar.gz"
}

restore() {
    local backup_file=$1
    if [ -z "${backup_file}" ] || [ ! -f "${backup_file}" ]; then
        log "ERROR" "请指定有效的备份文件（镜像备份.tar）"
        log "INFO" "可用备份：$(ls ${BASE_DIR}/backup/*.tar 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi

    local data_backup_file=$(echo "${backup_file}" | sed 's/\.tar$/_data.tar.gz/')
    local container_name=$(basename "${backup_file}" | cut -d'_' -f1)

    log "INFO" "开始恢复容器：${container_name}"

    # 步骤1：加载镜像
    log "INFO" "加载备份镜像：${backup_file}"
    docker load -i "${backup_file}"
    local image_name=$(docker images | grep "${container_name}_backup" | awk '{print $1":"$2}' | head -1)

    # 步骤2：创建并启动容器
    docker run -d --name "${container_name}" --gpus all -v "${HOME}/pytorch-prod/data:/app/data" "${image_name}" tail -f /dev/null

    # 步骤3：恢复数据目录
    if [ -f "${data_backup_file}" ]; then
        log "INFO" "恢复数据目录：${data_backup_file} → ${HOME}/pytorch-prod/data"
        mkdir -p "${HOME}/pytorch-prod/data"
        tar -zxf "${data_backup_file}" -C "${HOME}/pytorch-prod/data" --strip-components=1
    else
        log "WARN" "数据备份文件不存在：${data_backup_file}，跳过数据恢复"
    fi

    log "INFO" "容器恢复完成！容器名称：${container_name}"
}

# 5. 清理无用镜像/容器
cleanup() {
    log "INFO" "开始清理Docker资源..."

    # 停止所有停止的容器
    log "INFO" "停止所有退出的容器"
    docker stop $(docker ps -aq --filter "status=exited") >/dev/null 2>&1 || true

    # 删除所有停止的容器
    log "INFO" "删除所有停止的容器"
    docker rm $(docker ps -aq --filter "status=exited") >/dev/null 2>&1 || true

    # 删除无用镜像（悬空镜像）
    log "INFO" "删除悬空镜像（<none>:<none>）"
    docker rmi $(docker images -aq --filter "dangling=true") >/dev/null 2>&1 || true

    # 清理Docker缓存
    log "INFO" "清理Docker构建缓存"
    docker system prune -f >/dev/null 2>&1

    log "INFO" "清理完成！当前资源使用："
    docker system df
}

# 6. 查看容器状态
status() {
    local env=${1:-${DEFAULT_ENV}}
    load_config "${env}"

    log "INFO" "容器${CONTAINER_NAME}状态："
    docker inspect "${CONTAINER_NAME}" | jq '.[] | {Name: .Name, Status: .State.Status, GPU: .HostConfig.Devices, Mounts: .Mounts[].Source}'
}

# ===================== 帮助信息 =====================
usage() {
    echo -e "\n${TOOL_NAME} v${TOOL_VERSION}"
    echo -e "PyTorch Docker环境全生命周期管理工具\n"
    echo -e "用法：$0 [命令] [环境（默认dev）] [参数]\n"
    echo -e "核心命令："
    echo -e "  deploy    [env]        部署指定环境（dev/prod）"
    echo -e "  enter     [env]        进入指定环境的容器"
    echo -e "  start     [env]        启动指定环境的容器"
    echo -e "  stop      [env]        停止指定环境的容器"
    echo -e "  restart   [env]        重启指定环境的容器"
    echo -e "  backup    [env]        备份指定环境的容器（镜像+数据）"
    echo -e "  restore   <backup.tar> 从备份文件恢复容器"
    echo -e "  cleanup                清理无用镜像/容器/缓存"
    echo -e "  status    [env]        查看指定环境容器状态"
    echo -e "  help                   显示帮助信息\n"
    echo -e "示例："
    echo -e "  部署开发环境：./pytorch_manager.sh deploy dev"
    echo -e "  部署生产环境：./pytorch_manager.sh deploy prod"
    echo -e "  进入开发容器：./pytorch_manager.sh enter dev"
    echo -e "  备份生产容器：./pytorch_manager.sh backup prod"
    echo -e "  清理Docker资源：./pytorch_manager.sh cleanup"
}

# ===================== 主逻辑 =====================
main() {
    if [ $# -eq 0 ]; then
        usage
        exit 0
    fi

    case $1 in
        deploy)
            deploy "${2:-${DEFAULT_ENV}}"
            ;;
        enter)
            enter "${2:-${DEFAULT_ENV}}"
            ;;
        start)
            start "${2:-${DEFAULT_ENV}}"
            ;;
        stop)
            stop "${2:-${DEFAULT_ENV}}"
            ;;
        restart)
            restart "${2:-${DEFAULT_ENV}}"
            ;;
        backup)
            backup "${2:-${DEFAULT_ENV}}"
            ;;
        restore)
            restore "$2"
            ;;
        cleanup)
            cleanup
            ;;
        status)
            status "${2:-${DEFAULT_ENV}}"
            ;;
        help)
            usage
            ;;
        *)
            log "ERROR" "无效命令：$1"
            usage
            exit 1
            ;;
    esac
}

# 启动主函数
main "$@"