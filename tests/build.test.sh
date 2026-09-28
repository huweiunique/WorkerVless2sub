#!/usr/bin/env bash
set -euo pipefail

# 只模拟 Docker/Git 命令，不构建镜像、不触碰真实容器。
repo="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/project with spaces"
touch "$fixture/project with spaces/compose.yml" "$fixture/project with spaces/runtime.env"
export fixture

git() { printf 'git %s\n' "$*" >> "$fixture/commands"; }
docker() {
    printf 'docker %s\n' "$*" >> "$fixture/commands"
    case "$1 $2" in
        'image inspect') echo 'sha256:old' ;;
        'ps -q')
            case "$scenario" in
                empty) ;;
                duplicate) printf 'a\nb\nunrelated\n' ;;
                multiple) printf 'a\nc\nunrelated\n' ;;
                *) printf 'a\nunrelated\n' ;;
            esac ;;
        'inspect --format')
            local template="$3" id="$4"
            case "$template" in
                '{{.Config.Image}}')
                    if [[ "$id" == unrelated ]]; then echo nginx:latest
                    elif [[ "$scenario" == alias ]]; then echo another-tag:latest
                    else echo worker-vless2sub:latest; fi ;;
                '{{.Image}}')
                    if [[ "$id" == unrelated ]]; then echo sha256:other; else echo sha256:old; fi ;;
                *com.docker.compose.project.working_dir*) echo "$fixture/project with spaces" ;;
                *com.docker.compose.project.config_files*)
                    if [[ "$scenario" == missing ]]; then echo "$fixture/missing.yml"
                    else echo "$fixture/project with spaces/compose.yml"; fi ;;
                *com.docker.compose.project.environment_file*) echo "$fixture/project with spaces/runtime.env" ;;
                *com.docker.compose.project*) [[ "$scenario" == standalone ]] || echo fixture-project ;;
                *com.docker.compose.service*)
                    if [[ "$id" == c ]]; then echo worker-two; else echo worker-one; fi ;;
                *) return 91 ;;
            esac ;;
        'build -t') [[ "$scenario" != build-failure ]] ;;
        'compose version') ;;
        'compose -p')
            local override='' prior='' arg
            for arg in "$@"; do
                if [[ "$prior" == -f ]]; then override="$arg"; fi
                prior="$arg"
            done
            [[ -f "$override" ]] || return 92
            if [[ " $* " == *' config --images '* ]]; then
                if [[ "$scenario" == wrong-tag ]]; then echo other-image:latest; else echo worker-vless2sub:latest; fi
            fi
            if [[ " $* " == *' up '* && "$scenario" == update-failure ]]; then return 1; fi
            ;;
        'image prune') ;;
        *) return 94 ;;
    esac
}
export -f git docker

for scenario in empty normal duplicate multiple alias missing standalone wrong-tag build-failure update-failure; do
    export scenario
    : > "$fixture/commands"
    status=0
    REPO_DIR="$repo" bash "$repo/build.sh" > "$fixture/output" 2>&1 || status=$?
    case "$scenario" in
        missing|standalone|wrong-tag|build-failure|update-failure) [[ "$status" != 0 ]] ;;
        *) [[ "$status" == 0 ]] || { cat "$fixture/output"; exit 1; } ;;
    esac
    case "$scenario" in
        standalone)
            ! grep -q 'docker build' "$fixture/commands"
            ! grep -q ' up ' "$fixture/commands" ;;
        missing|wrong-tag|build-failure|empty) ! grep -q ' up ' "$fixture/commands" ;;
        multiple) [[ "$(grep -c ' up ' "$fixture/commands")" == 2 ]] ;;
        *) [[ "$(grep -c ' up ' "$fixture/commands")" == 1 ]] ;;
    esac
    case "$scenario" in
        missing|standalone|wrong-tag|build-failure|update-failure) ! grep -q 'image prune' "$fixture/commands" ;;
        *) grep -q 'image prune' "$fixture/commands" ;;
    esac
    if grep -q ' up ' "$fixture/commands"; then
        grep -q -- '--no-deps --no-build --pull never --force-recreate' "$fixture/commands"
        grep -q -- '--env-file' "$fixture/commands"
        if [[ "$scenario" == duplicate ]]; then
            grep -q -- '--scale worker-one=2' "$fixture/commands"
        else
            grep -q -- '--scale worker-one=1' "$fixture/commands"
        fi
    fi
    echo "通过: $scenario"
done
