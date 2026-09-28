#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR"

IMAGE_NAME="worker-vless2sub:latest"

echo "[1/3] 拉取最新代码..."
git pull --ff-only

echo "[2/3] 构建 Docker 镜像: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" .

echo "[3/3] 清理无效旧镜像..."
docker image prune -f

echo
echo "构建完成: $IMAGE_NAME"
echo "请在 1Panel 编排中使用 image: worker-vless2sub:latest"
