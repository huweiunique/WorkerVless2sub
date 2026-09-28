#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$REPO_DIR"
IMAGE_NAME="worker-vless2sub:latest"

echo "[1/4] 拉取最新代码..."
git pull --ff-only

# 在 latest 被替换前，记录当前使用该镜像的运行中容器及其原编排。
old_image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE_NAME" 2>/dev/null || true)"
container_ids="$(docker ps -q)"
projects=() services=() directories=() configs=() environments=() replicas=()
label() { docker inspect --format "{{with index .Config.Labels \"$2\"}}{{.}}{{end}}" "$1"; }
for id in $container_ids; do
    image="$(docker inspect --format '{{.Config.Image}}' "$id")"
    image_id="$(docker inspect --format '{{.Image}}' "$id")"
    if [[ "$image" != "$IMAGE_NAME" && "$image" != "${IMAGE_NAME%:latest}" && ( -z "$old_image_id" || "$image_id" != "$old_image_id" ) ]]; then continue; fi
    project="$(label "$id" com.docker.compose.project)"
    service="$(label "$id" com.docker.compose.service)"
    if [[ -z "$project" || -z "$service" ]]; then
        echo "容器 $id 不是 Compose 容器，无法仅靠重启切换镜像，请按原启动命令重建。" >&2
        exit 1
    fi
    duplicate=false
    for i in "${!services[@]}"; do
        if [[ "${projects[i]}/${services[i]}" == "$project/$service" ]]; then
            replicas[i]=$((replicas[i] + 1)); duplicate=true; break
        fi
    done
    if [[ "$duplicate" == true ]]; then continue; fi
    projects+=("$project"); services+=("$service"); replicas+=(1)
    directories+=("$(label "$id" com.docker.compose.project.working_dir)")
    configs+=("$(label "$id" com.docker.compose.project.config_files)")
    environments+=("$(label "$id" com.docker.compose.project.environment_file)")
done

echo "[2/4] 构建 Docker 镜像: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" .

echo "[3/4] 将原有服务替换为新镜像并启动..."
for i in "${!services[@]}"; do
    (
        [[ -n "${directories[i]}" && -n "${configs[i]}" ]] || { echo "原 Compose 路径缺失" >&2; exit 1; }
        cd "${directories[i]}"
        compose=(docker compose -p "${projects[i]}")
        IFS=',' read -r -a files <<< "${configs[i]}"
        for file in "${files[@]}"; do compose+=(-f "$file"); done
        if [[ -n "${environments[i]}" ]]; then
            IFS=',' read -r -a files <<< "${environments[i]}"
            for file in "${files[@]}"; do compose+=(--env-file "$file"); done
        fi
        configured_image="$("${compose[@]}" config --images "${services[i]}")"
        if [[ "$configured_image" != "$IMAGE_NAME" && "$configured_image" != "${IMAGE_NAME%:latest}" ]]; then
            echo "请将 ${projects[i]}/${services[i]} 的编排镜像设置为 $IMAGE_NAME 后重试。" >&2
            exit 1
        fi
        "${compose[@]}" up -d --no-deps --no-build --pull never --force-recreate --scale "${services[i]}=${replicas[i]}" "${services[i]}"
    )
done
if ((${#services[@]} == 0)); then echo "没有匹配的运行中容器，仅构建镜像。"; fi

echo "[4/4] 清理无效旧镜像..."
docker image prune -f
echo "构建及更新完成: $IMAGE_NAME"
