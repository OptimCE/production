#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose/docker-compose.yml"
ENV_FILE="docker-compose/.env"
WAIT_INIT_SECONDS=30
WAIT_BACKEND_SECONDS=30
PULL_IMAGES=true

usage() {
    cat <<'EOF'
Usage: ./docker-stack.sh <command> [options]

Commands:
  start      Pull images (optional) and start init, backend, then frontend
  stop       Stop init, backend, and frontend profiles
  restart    Stop then start
  help       Show this help message

Options (for start/restart):
  --no-pull                  Skip image pull before starting
  --wait-init <seconds>      Wait after init profile (default: 30)
  --wait-backend <seconds>   Wait after backend profile (default: 30)
EOF
}

resolve_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker-compose)
        echo "Docker Compose detected: docker-compose"
        return
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker compose)
        echo "Docker Compose detected: docker compose"
        return
    fi

    echo "Docker Compose is not installed."
    exit 1
}

check_docker_service() {
    if ! systemctl is-active --quiet docker; then
        echo "Docker service is not active."
        exit 1
    fi
    echo "Docker service is active."
}

compose() {
    "${DOCKER_COMPOSE_CMD[@]}" "$@"
}

start_stack() {
    check_docker_service

    if [ "$PULL_IMAGES" = true ]; then
        compose -f "$COMPOSE_FILE" --profile init --profile backend --profile frontend pull
    fi

    compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" up -d

    echo "Waiting for initialization to complete..."
    sleep "$WAIT_INIT_SECONDS"

    compose -f "$COMPOSE_FILE" --profile backend --env-file "$ENV_FILE" up -d

    echo "Waiting for backend initialization to complete..."
    sleep "$WAIT_BACKEND_SECONDS"

    compose -f "$COMPOSE_FILE" --profile frontend --env-file "$ENV_FILE" up -d
}

stop_stack() {
    compose -f "$COMPOSE_FILE" --profile init --profile backend --profile frontend down
}

parse_start_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-pull)
                PULL_IMAGES=false
                ;;
            --wait-init)
                shift
                [ "$#" -gt 0 ] || { echo "Missing value for --wait-init"; exit 1; }
                WAIT_INIT_SECONDS="$1"
                ;;
            --wait-backend)
                shift
                [ "$#" -gt 0 ] || { echo "Missing value for --wait-backend"; exit 1; }
                WAIT_BACKEND_SECONDS="$1"
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

main() {
    if [ "$#" -lt 1 ]; then
        usage
        exit 1
    fi

    local command="$1"
    shift

    resolve_compose_cmd

    case "$command" in
        start)
            parse_start_options "$@"
            start_stack
            ;;
        stop)
            stop_stack
            ;;
        restart)
            parse_start_options "$@"
            stop_stack
            start_stack
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"