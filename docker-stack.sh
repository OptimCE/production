#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose/docker-compose.yml"
ENV_FILE="docker-compose/.env"
WAIT_INIT_SECONDS=10
WAIT_BACKEND_SECONDS=10
PULL_IMAGES=true

usage() {
    cat <<'EOF'
Usage: ./docker-stack.sh <command> [options]

Commands:
    start      Pull images (optional) and start init, backend, then frontend
    stop       Stop init, backend, and frontend profiles
    restart    Stop then start
    verify     Prove the database isolation and the CRM grant matrix
    help       Show this help message

Options (for start/restart):
    --no-pull                  Skip image pull before starting
    --wait-init <seconds>      Wait after init profile (default: 10)
    --wait-backend <seconds>   Wait after backend profile (default: 10)
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
    echo "Running backups before stopping..."
    do_backup
    compose -f "$COMPOSE_FILE" --profile init --profile backend --profile frontend down
}

do_backup() {
    # Two jobs, because there are two instances. `db-backup` loops the five
    # application databases plus the cluster globals; `keycloak-db-backup` covers
    # the separate Keycloak instance. A failure is reported but does not abort the
    # other job, so one broken dump cannot block the shutdown.
    local jobs="db-backup keycloak-db-backup"

    for job in $jobs; do
        echo "Running ${job}..."
        compose -f "$COMPOSE_FILE" --profile backup --env-file "$ENV_FILE" run --rm "$job" || echo "${job} failed"
    done
    echo "Backups completed."
}

verify_stack() {
    # Runs both scripts inside the postgres-init image, so no psql is needed on
    # the host and all five role passwords come from the environment compose
    # already assembles.
    #
    # MSYS_NO_PATHCONV=1 is not optional under Git Bash on Windows: it would
    # otherwise rewrite /postgres/verify/... into a C:\ path before Docker ever
    # sees it, and the container fails with `stat C:/Program: no such file`.
    #
    # `--entrypoint sh <script>` rather than `--entrypoint <script>`: the scripts
    # arrive over a bind mount, so their executable bit is whatever the host
    # filesystem says. Docker Desktop on Windows reports every bind-mounted file
    # as executable; a Linux host reports the real mode, and git records these as
    # 100644. Running them THROUGH sh needs no exec bit and behaves the same on
    # both. (The bit is set in git as well, but do not rely on it alone — a
    # checkout on a filesystem that cannot store it silently loses it.)
    local status=0

    echo "Proving database isolation..."
    if ! MSYS_NO_PATHCONV=1 compose -f "$COMPOSE_FILE" --profile backend --env-file "$ENV_FILE" \
        run --rm --no-deps --entrypoint sh postgres-init /postgres/verify/isolation.sh; then
        status=1
    fi

    echo
    echo "Proving every granted CRM write lands..."
    if ! MSYS_NO_PATHCONV=1 compose -f "$COMPOSE_FILE" --profile backend --env-file "$ENV_FILE" \
        run --rm --no-deps --entrypoint sh postgres-init /postgres/verify/positive-writes.sh; then
        status=1
    fi

    if [ "$status" -ne 0 ]; then
        echo
        echo "Verification FAILED. See docker-compose/postgres/README.md."
        exit 1
    fi
    echo
    echo "Verification passed."
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
        verify)
            verify_stack
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