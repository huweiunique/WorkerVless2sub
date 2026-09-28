#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR"

echo "[1/3] 拉取最新代码..."
git pull --ff-only

echo "[2/3] 构建 Docker 镜像..."
docker compose build

echo "[3/3] 清理无效旧镜像..."
docker image prune -f

echo
echo "构建完成。请在 1Panel 的 Docker 编排中重建/启动该服务。"
