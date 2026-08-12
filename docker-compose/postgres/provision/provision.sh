#!/bin/sh
# ===========================================================================
# Converges the unified Postgres instance on EVERY `up`.
#
# This is the SINGLE provisioning path. /docker-entrypoint-initdb.d is
# deliberately left unmounted: those scripts run only on an empty data directory
# and only against POSTGRES_DB, so they can neither converge a rotated password
# nor reach a second database. Two mechanisms would also be two things that can
# diverge — see postgres/README.md.
#
# The MIGRATION reuses this file UNCHANGED, in two passes. See
# DATABASE_CONSOLIDATION.md:
#     pass 1, before pg_restore:  SKIP_SCHEMAS=1 sh provision.sh
#     pass 2, after pg_restore:   sh provision.sh
#
# POSIX sh (busybox ash). Three details that are easy to get wrong and are load
# bearing here:
#   * `while ... done <<EOF`, never `echo ... | while`. A pipeline puts the loop
#     body in a subshell in ash; here-doc redirection does not.
#   * `if ...; then ...; fi`, never a bare `[ x ] && { ...; }` statement — a
#     false test makes the whole list return 1 and, as the complete command,
#     trips `set -e`.
#   * Multiple -f files in ONE psql invocation share one session, in order. That
#     is how 21-set-role.sql becomes a prelude without editing any schema file.
# ===========================================================================
set -eu

SQL_DIR=${SQL_DIR:-/postgres/provision}
SCHEMA_DIR=${SCHEMA_DIR:-/schemas}
SKIP_SCHEMAS=${SKIP_SCHEMAS:-0}

# ON_ERROR_STOP=1 on every invocation. A failed statement aborts psql, `set -e`
# aborts this script, the container exits non-zero, and every service depending
# on it with `condition: service_completed_successfully` refuses to start.
#
# That is the point: there is no state in which the stack comes up with half its
# grants. A missing CRM grant produces NO application error (the annexes swallow
# it), so a partial provision would be invisible until an audit trail was
# silently missing.
PSQL="psql --no-psqlrc --quiet -v ON_ERROR_STOP=1"

log() { printf '[postgres-init] %s\n' "$*"; }

# The registry. One line per database: <database>|<owner role>|<schema file>
#
# Adding another annexe service means one line here, one role in 00-roles.sql,
# one row plus a GRANT CONNECT in 10-databases.sql, and one schema mount in
# docker-compose.yml.
#
# Two roles are deliberately NOT here because they own no database:
#   * `keycloak` — its own instance entirely.
#   * `notification_dispatch_svc` — a role with crm_db grants and nothing else.
DATABASES='crm_db|crm_svc|crm_db.sql
allocation_key_local|allocation_key_svc|allocation_key_local.sql
simulation_key_local|simulation_key_svc|simulation_key_local.sql
news_board_local|news_board_svc|news_board_local.sql
billing_local|billing_svc|billing_local.sql
administrative_document_local|administrative_document_svc|administrative_document_local.sql'

# --- 0. Wait ---------------------------------------------------------------
# `depends_on: service_healthy` already covers the compose path. This makes
# `docker compose run --rm --no-deps postgres-init` work too.
i=0
until pg_isready -q; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        log "postgres never became ready after 60s"
        exit 1
    fi
    sleep 1
done

# --- 1. Roles --------------------------------------------------------------
# Creates if absent, then ALWAYS re-asserts every password, so rotating a
# ${*_DB_PASSWORD} in docker-compose/.env takes effect on the next `up` with no
# data wipe. Note `restart`, not `start` — a RUNNING application container keeps
# the environment it was created with.
log "roles"
$PSQL -d postgres \
    -v crm_password="$CRM_DB_PASSWORD" \
    -v allocation_key_password="$ALLOCATION_KEY_DB_PASSWORD" \
    -v simulation_key_password="$SIMULATION_KEY_DB_PASSWORD" \
    -v news_board_password="$NEWS_BOARD_DB_PASSWORD" \
    -v billing_password="$BILLING_DB_PASSWORD" \
    -v administrative_document_password="$ADMINISTRATIVE_DOCUMENT_DB_PASSWORD" \
    -v notification_dispatch_password="$NOTIFICATION_DISPATCH_DB_PASSWORD" \
    -f "$SQL_DIR/00-roles.sql"

# --- 2. Databases + CONNECT ACLs -------------------------------------------
log "databases"
$PSQL -d postgres -f "$SQL_DIR/10-databases.sql"

# --- 3. Schema ownership and schemas ----------------------------------------
while IFS='|' read -r db owner schema; do
    if [ -z "$db" ]; then continue; fi

    # Always: make the service role the DIRECT owner of schema public.
    $PSQL -d "$db" -v owner="$owner" -f "$SQL_DIR/20-schema-owner.sql"

    # ---- schema, guarded --------------------------------------------------
    #
    # A schema is applied ONLY when the database has no ordinary or partitioned
    # relation in `public`.
    #
    # In production this means the mounted schemas are effectively never
    # applied: the migration restores real data first, and every subsequent
    # start finds the databases populated. They are mounted anyway because they
    # are the disaster-recovery baseline — the only thing that rebuilds this
    # stack from an empty volume.
    #
    # The decisive reason for the guard is crm_db. schemas/crm_db.sql:1 opens
    # with `DROP SCHEMA IF EXISTS public CASCADE`, so a second pass would
    # silently DESTROY production data. It is also the v0 baseline, not the
    # current schema — optimce-migrator has carried crm_db well past it — so
    # re-applying it would be wrong even if it were harmless.
    #
    # The five annexe schema.sql files are, by contrast, idempotent (CREATE
    # TABLE / CREATE INDEX IF NOT EXISTS throughout, DROP TRIGGER IF EXISTS
    # before every CREATE TRIGGER). They are guarded anyway: replay buys nothing
    # (`CREATE TABLE IF NOT EXISTS` never adds a COLUMN, so it is not a migration
    # mechanism), and one rule for all six databases is one rule to reason about
    # instead of two.
    #
    # A HALF-applied schema reads as non-empty and is therefore skipped. That is
    # correct: the run that half-applied it exited non-zero, so no dependent
    # service ever started.
    if [ "$SKIP_SCHEMAS" = "1" ]; then
        log "$db: schema skipped (SKIP_SCHEMAS=1)"
    elif [ ! -f "$SCHEMA_DIR/$schema" ]; then
        log "$db: no $SCHEMA_DIR/$schema mounted — schema skipped"
    else
        empty=$($PSQL -d "$db" -tAc "SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p'))")
        if [ "$empty" = "t" ]; then
            log "$db: applying $schema as $owner"
            $PSQL -d "$db" -v owner="$owner" \
                -f "$SQL_DIR/21-set-role.sql" \
                -f "$SCHEMA_DIR/$schema"
        else
            log "$db: already populated — schema not re-applied"
        fi
    fi

    # ---- no seed step, deliberately ---------------------------------------
    #
    # The monorepo's copy of this script applies /seeds/<db>/*.sql here on EVERY
    # run. That is right for development — it lets newly registered reference
    # data land without a wipe — and wrong here.
    #
    # In production, anything that changes a database is applied ONCE and
    # recorded, so that what a database contains is a function of its migration
    # history and not of how many times it has been restarted. Reference data is
    # no exception: it ships as a migration, like every other change. See
    # DATABASE_CONSOLIDATION.md §9.8.
    #
    # If you are diffing this file against the monorepo's, that missing block is
    # the one intentional behavioural difference between them.
done <<EOF
$DATABASES
EOF

# --- 4. Grants -------------------------------------------------------------
# Unconditional, every run. ALTER DEFAULT PRIVILEGES is not retroactive, so this
# is what converges after an optimce-migrator release adds a table, and after a
# role is added to the matrix.
log "crm grants"
$PSQL -d crm_db -f "$SQL_DIR/30-crm-grants.sql"

log "done"
exit 0
