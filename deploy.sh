#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR"

echo "[1/4] 拉取最新代码..."
git pull --ff-only

echo "[2/4] 构建并启动容器..."
docker compose up -d --build

echo "[3/4] 清理无效镜像..."
docker image prune -f

echo "[4/4] 当前容器状态:"
docker compose ps
