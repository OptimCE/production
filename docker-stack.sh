#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose/docker-compose.yml"
ENV_FILE="docker-compose/.env"
WAIT_INIT_SECONDS=10
WAIT_BACKEND_SECONDS=10
PULL_IMAGES=true
MIGRATE_DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: ./docker-stack.sh <command> [options]

Commands:
    start      Pull images (optional) and start init, backend, then frontend
    stop       Stop init, backend, and frontend profiles
    restart    Stop then start
    migrate    Apply pending database migrations, then re-converge the grants
    verify     Prove the database isolation and the CRM grant matrix
    help       Show this help message

Options (for start/restart):
    --no-pull                  Skip image pull before starting
    --wait-init <seconds>      Wait after init profile (default: 10)
    --wait-backend <seconds>   Wait after backend profile (default: 10)

Options (for migrate):
    --no-pull                  Skip the optimce-migrator image pull
    --dry-run                  Report pending migrations without applying them
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

    check_frontend_config
    compose -f "$COMPOSE_FILE" --profile frontend --env-file "$ENV_FILE" up -d
}

check_frontend_config() {
    # crm-frontend bind-mounts a SINGLE FILE, config.json, over the one inside the
    # image. Docker creates a missing bind source as a DIRECTORY, and nginx then
    # serves a directory where the SPA expects its configuration: the app loads to
    # a blank page with nothing useful in any log.
    #
    # The obvious fix - `depends_on: crm-frontend-config` on crm-frontend - is not
    # available: crm-frontend-config is in the `init` profile and crm-frontend in
    # `frontend`, and compose rejects a depends_on target that is not in an enabled
    # profile ("depends on undefined service"). It would break `--profile frontend
    # up -d` outright. This check is the substitute; `start` runs the init profile
    # first, so by here the file must exist.
    local cfg="docker-compose/crm-frontend-config/config.json"

    if [ -d "$cfg" ]; then
        echo "ERROR: ${cfg} is a DIRECTORY."
        echo "Docker created it because the init profile had not rendered the file yet."
        echo "Remove it and re-run the init profile:"
        echo "    rmdir ${cfg}"
        echo "    ${DOCKER_COMPOSE_CMD[*]} -f ${COMPOSE_FILE} --profile init --env-file ${ENV_FILE} up -d"
        exit 1
    fi

    if [ ! -f "$cfg" ]; then
        echo "ERROR: ${cfg} does not exist."
        echo "It is rendered from config.template.json by the init profile."
        echo "Run the init profile before the frontend profile."
        exit 1
    fi
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

migrate_stack() {
    # The migrator is in the `migration` profile but depends_on postgres and
    # postgres-init, which are in `backend` - so BOTH profiles must be active or
    # compose refuses the project with "depends on undefined service". Naming the
    # service keeps the run scoped to it; its dependencies are already up.
    check_docker_service

    if [ "$PULL_IMAGES" = true ]; then
        compose -f "$COMPOSE_FILE" --profile backend --profile migration pull optimce-migrator
    fi

    if [ "$MIGRATE_DRY_RUN" = true ]; then
        echo "Reporting pending migrations (nothing will be applied)..."
        compose -f "$COMPOSE_FILE" --profile backend --profile migration --env-file "$ENV_FILE" \
            run --rm optimce-migrator --dry-run
        return
    fi

    echo "Applying pending migrations..."
    echo
    echo "NOTE: the annexe migrations take ACCESS EXCLUSIVE on generation/simulation."
    echo "      With lock_timeout at its default of 0, a running allocation-key or"
    echo "      simulation-key worker holding a transaction makes this wait forever -"
    echo "      and every later query then queues behind it. Stop those four services"
    echo "      first, or run this before the backend profile is up."
    echo

    # `|| status=$?` rather than letting `set -e` abort here: each migration commits
    # in its own transaction, so a failure part-way leaves earlier ones APPLIED and
    # ungranted. postgres-init must run over whatever landed before we report the
    # failure - a missing CRM grant is silent at runtime, not loud.
    local status=0
    compose -f "$COMPOSE_FILE" --profile backend --profile migration --env-file "$ENV_FILE" \
        run --rm optimce-migrator || status=$?

    echo
    echo "Re-converging grants over whatever the migrator created..."
    compose -f "$COMPOSE_FILE" --profile backend --env-file "$ENV_FILE" run --rm postgres-init

    if [ "$status" -ne 0 ]; then
        echo
        echo "Migration FAILED (exit ${status}). Grants were converged over what landed."
        echo "See DATABASE_CONSOLIDATION.md 9.1 before retrying."
        exit "$status"
    fi

    echo
    echo "Migrations applied and grants converged. Run './docker-stack.sh verify' next."
}

parse_migrate_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-pull)
                PULL_IMAGES=false
                ;;
            --dry-run)
                MIGRATE_DRY_RUN=true
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
        migrate)
            parse_migrate_options "$@"
            migrate_stack
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