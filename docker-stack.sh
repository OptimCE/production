#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose/docker-compose.yml"
ENV_FILE="docker-compose/.env"
WAIT_INIT_SECONDS=10
WAIT_BACKEND_SECONDS=10
PULL_IMAGES=true
MIGRATE_DRY_RUN=false
# The live-data services gate on postgres/postgres-init, which live in `backend`;
# compose rejects a depends_on target outside the enabled profiles, so every
# command that names the live-data profile enables both.
LIVE_DATA_PROFILES=(--profile backend --profile live-data)

usage() {
    cat <<'EOF'
Usage: ./docker-stack.sh <command> [options]

Commands:
    start       Pull images (optional) and start init, backend, frontend, then live-data
    stop        Stop every profile (backups first)
    restart     Stop then start
    migrate     Apply pending database migrations, then re-converge the grants
    verify      Prove the database isolation and the CRM grant matrix
    survey-ean  Report every stored EAN that is not 18 digits (read-only)
    mqtt-cert   Issue the MQTT broker's certificate (once; needs the DNS record)
    renew-certs Renew every certificate due, reload nginx and the broker (cron)
    help        Show this help message

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
        # Separately and non-fatally: a live-data image that cannot be pulled
        # (e.g. its GHCR package still private) must not abort the deploy of
        # everything else. start_live_data reports what that means.
        if live_data_enabled; then
            compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${LIVE_DATA_PROFILES[@]}" \
                pull mosquitto live-data live-data-worker \
                || echo "WARNING: could not pull the live-data images (see docs/runbooks/live-data.md). Continuing."
        fi
    fi

    compose -f "$COMPOSE_FILE" --profile init --env-file "$ENV_FILE" up -d

    echo "Waiting for initialization to complete..."
    sleep "$WAIT_INIT_SECONDS"

    compose -f "$COMPOSE_FILE" --profile backend --env-file "$ENV_FILE" up -d

    echo "Waiting for backend initialization to complete..."
    sleep "$WAIT_BACKEND_SECONDS"

    check_frontend_config
    compose -f "$COMPOSE_FILE" --profile frontend --env-file "$ENV_FILE" up -d

    start_live_data
}

start_live_data() {
    # LAST and NON-FATAL, deliberately. live-data is the only part of the
    # platform with public infrastructure of its own (the MQTT broker on 8883, its
    # DNS name and certificate), so it is also the part most likely to be
    # half-configured - and nothing else depends on it. Started inside the
    # backend step, one failing one-shot here would abort this script before the
    # reverse proxy came up. Here, a failure is reported and the site stays up.
    #
    # `up -d` over backend + live-data is a no-op for the backend services that
    # are already running; the idempotent backend one-shots (postgres-init,
    # minio-init) run once more, which is what the live-data services gate on.
    if ! live_data_enabled; then
        echo "live-data: off (LIVE_DATA_ENABLED=false in ${ENV_FILE}) - not started."
        return 0
    fi
    echo "Starting live-data (a failure here leaves the rest of the platform running)..."
    if ! compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${LIVE_DATA_PROFILES[@]}" up -d; then
        echo
        echo "WARNING: the live-data profile did not start cleanly. Everything else is up."
        echo "  Inspect: ${DOCKER_COMPOSE_CMD[*]} -f ${COMPOSE_FILE} --env-file ${ENV_FILE} --profile backend --profile live-data ps -a"
        echo "  Usual causes and fixes: docs/runbooks/live-data.md"
    fi
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
    # live-data included: left out, its containers keep running and `down` then
    # fails to remove the networks they are still attached to.
    compose -f "$COMPOSE_FILE" --profile init --profile backend --profile frontend --profile live-data down
}

do_backup() {
    # Three jobs. `db-backup` loops the application databases plus the cluster
    # globals; `keycloak-db-backup` covers the separate Keycloak instance;
    # `mosquitto-backup` copies the broker's dynamic-security.json (every enrolled
    # device's credential - it is in no database). A failure is reported but does
    # not abort the others, so one broken job cannot block the shutdown.
    local jobs="db-backup keycloak-db-backup mosquitto-backup"

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

survey_ean() {
    # Read-only: every statement in the script is a SELECT. Same container, and
    # the same MSYS_NO_PATHCONV and `--entrypoint sh` reasoning, as verify_stack.
    #
    # Run it BEFORE `migrate` whenever the migrator carries CRM migration 12: that
    # migration refuses to add the meter.ean CHECK while any row is not 18 digits.
    # The exit status is the script's own - 0 clean, 1 non-conforming meter.ean
    # rows, 2 a probe could not run - and `set -e` hands it straight back.
    #
    # Deliberately NOT part of `verify`: that is a pass/fail proof of isolation
    # and grants, and one legacy row must not turn it red.
    MSYS_NO_PATHCONV=1 compose -f "$COMPOSE_FILE" --profile backend --env-file "$ENV_FILE" \
        run --rm --no-deps --entrypoint sh postgres-init /postgres/verify/ean-survey.sh
}

live_data_enabled() {
    # LIVE_DATA_ENABLED=false in .env keeps the live-data profile off (a staging
    # stack, or the annexe parked). Absent or anything else = on. `stop` brings
    # the profile down either way.
    local v
    v=$({ grep -E '^LIVE_DATA_ENABLED=' "$ENV_FILE" || true; } | tail -n 1 | cut -d= -f2- | tr -d "\"' \r")
    [ "$v" != "false" ]
}

broker_host() {
    # The value as written in .env, quotes and CR stripped. Read here rather than
    # through compose so the error can name the file to fix.
    #
    # `|| true` is load-bearing: with no such line grep exits 1, pipefail fails
    # the pipeline, and under `set -e` the caller's `host=$(broker_host)` would
    # end the script silently instead of printing which variable is missing.
    { grep -E '^LIVE_DATA_BROKER_PUBLIC_HOST=' "$ENV_FILE" || true; } | tail -n 1 | cut -d= -f2- | tr -d "\"' \r"
}

mqtt_cert() {
    # FIRST issuance of the MQTT broker's certificate: a separate Let's Encrypt
    # lineage for LIVE_DATA_BROKER_PUBLIC_HOST, RSA, chain pinned to ISRG Root X1
    # (see certbot-mqtt in docker-compose.yml). Renewals go through renew-certs.
    #
    # Needs the DNS record pointing at this host, and the reverse proxy answering
    # on port 80 - any running stack does, before or after this release.
    check_docker_service
    local host
    host=$(broker_host)
    if [ -z "$host" ]; then
        echo "LIVE_DATA_BROKER_PUBLIC_HOST is not set in ${ENV_FILE}."
        exit 1
    fi
    echo "Requesting the broker certificate for ${host} (HTTP-01 over port 80)..."
    compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile certs run --rm certbot-mqtt
    refresh_broker_certificate
}

refresh_broker_certificate() {
    # Copies the current certificate into the broker's own volume, and restarts
    # the broker ONLY if the certificate changed: a no-op renewal must not drop
    # every device connection. Never fatal - the broker keeps its old copy.
    local out
    if ! out=$(compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${LIVE_DATA_PROFILES[@]}" \
            run --rm mosquitto-certs 2>&1); then
        printf '%s\n' "$out"
        echo "WARNING: mosquitto-certs failed; the broker keeps the certificate it has."
        return 0
    fi
    printf '%s\n' "$out"
    if printf '%s\n' "$out" | grep -q 'certificate changed: yes'; then
        if [ -n "$(compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${LIVE_DATA_PROFILES[@]}" ps -q mosquitto)" ]; then
            echo "Restarting the broker to load the new certificate (devices reconnect on their own)..."
            compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "${LIVE_DATA_PROFILES[@]}" restart mosquitto
        else
            echo "The broker is not running; it loads the certificate when the live-data profile starts."
        fi
    fi
}

renew_certs() {
    # Every lineage certbot holds - the web certificate and the broker's - in one
    # pass, then each consumer reloads. Meant for cron; weekly is plenty, since
    # certbot only renews within 30 days of expiry:
    #
    #   17 4 * * 1  cd /home/production && ./docker-stack.sh renew-certs >> /var/log/optimce-renew-certs.log 2>&1
    #
    # The broker half is the one that cannot be skipped: without it, every device
    # fails its TLS handshake within the same hour about 90 days in, while the
    # web application looks perfectly fine (plan §15.1).
    check_docker_service
    echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') renewing every certificate that is due..."
    local status=0
    compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile frontend \
        run --rm certbot renew --webroot -w /webroot --non-interactive || status=$?

    if [ -n "$(compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile frontend ps -q reverse-proxy)" ]; then
        compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile frontend \
            exec -T reverse-proxy nginx -s reload || status=1
    fi

    if [ -n "$(broker_host)" ]; then
        refresh_broker_certificate
    fi

    # The expiry monitor: one line per lineage with its remaining validity. An
    # expiry nobody watches is invisible until devices go silent.
    compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile frontend \
        run --rm certbot certificates 2>/dev/null | grep -E 'Certificate Name|Expiry Date' || true

    if [ "$status" -ne 0 ]; then
        echo "Renewal reported a FAILURE (exit ${status}) - read the certbot output above."
        exit "$status"
    fi
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
        echo "Each migration commits separately - check schema_version in each"
        echo "database before retrying."
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
        survey-ean)
            survey_ean
            ;;
        mqtt-cert)
            mqtt_cert
            ;;
        renew-certs)
            renew_certs
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