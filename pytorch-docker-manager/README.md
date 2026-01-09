# pytorch-docker-manager
PyTorch Docker环境全生命周期管理工具，支持多环境配置、资源管控、健康检查、日志持久化、一键备份恢复，开箱即用适配开发/生产场景。

[![Shell Script](https://img.shields.io/badge/Shell-Script-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Docker](https://img.shields.io/badge/Docker-2496ED.svg)](https://www.docker.com/)
[![PyTorch](https://img.shields.io/badge/PyTorch-EE4C2C.svg)](https://pytorch.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 核心特性
### 🚀 多环境适配
- **开发环境（dev）**：交互式运行、无资源限制、本地目录挂载，适配调试场景
- **生产环境（prod）**：后台运行、CPU/内存限制、多端口映射、自动重启，适配服务部署

### 🛡️ 稳定性保障
- 容器健康检查：定时检测状态，异常自动重启（可配置重启阈值）
- 日志持久化：容器日志、PyTorch运行日志全量挂载到宿主机，支持日志轮转
- 版本兼容性检测：自动检测Docker/CUDA/nvidia-docker版本，规避兼容性问题

### 💾 数据安全
- 一键备份：完整备份容器镜像+数据目录，避免环境配置丢失
- 一键恢复：从备份文件快速恢复容器，支持跨机器迁移
- 数据目录持久化：核心数据独立挂载，容器删除不丢失数据

### 🎛️ 资源管控
- CPU/内存限制：避免容器占用过多宿主机资源
- 端口映射：支持Jupyter/TensorBoard/自定义服务多端口配置
- 镜像清理：一键清理无用镜像/容器/缓存，节省磁盘空间

## 快速开始
### 1. 环境准备
```bash
# 克隆项目
git clone https://github.com/你的用户名/pytorch-docker-manager.git
cd pytorch-docker-manager

# 赋予执行权限
chmod +x pytorch_manager.sh scripts/*.sh

# 安装依赖（以CentOS为例）
yum install -y docker jq bc
systemctl enable --now docker

# 安装nvidia-docker（GPU环境）
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.repo | tee /etc/yum.repos.d/nvidia-docker.repo
yum install -y nvidia-docker2
systemctl restart docker


3.核心命令
部署开发环境（交互式，适合本地调试）
# 部署dev环境（默认）
./pytorch_manager.sh deploy dev

# 进入开发容器
./pytorch_manager.sh enter dev

部署生产环境（后台运行，适合服务部署）


# 部署prod环境
./pytorch_manager.sh deploy prod

# 查看生产容器状态
./pytorch_manager.sh status prod


# 启动/停止/重启容器
./pytorch_manager.sh start prod
./pytorch_manager.sh stop prod
./pytorch_manager.sh restart prod

# 备份生产容器（镜像+数据）
./pytorch_manager.sh backup prod

# 从备份恢复容器
./pytorch_manager.sh restore ./backup/pytorch-prod_20260109_100000.tar

# 清理无用镜像/容器/缓存
./pytorch_manager.sh cleanup