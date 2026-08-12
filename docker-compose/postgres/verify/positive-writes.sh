#!/bin/sh
# ===========================================================================
# The script that matters most. Proves every granted CRM write actually LANDS.
#
# "We saw no 500s" is not evidence here. The annexes' audit write swallows its
# own exception: core/audit_log/service.py wraps the INSERT in a begin_nested()
# SAVEPOINT under a blanket `except Exception: logger.exception(...)`. A missing
# grant therefore does NOT raise — the business transaction commits, the API
# returns 200, and the audit trail disappears with only a log line to show for
# it. Only allocation-key-generation's CRM domain write fails loudly.
#
# So the grants must be proved POSITIVELY, per role.
#
#     ./docker-stack.sh verify
#
# or directly:
#
#     docker compose -f docker-compose/docker-compose.yml --env-file docker-compose/.env \
#       run --rm --no-deps --entrypoint /postgres/verify/positive-writes.sh postgres-init
#
# SAFE ON LIVE DATA. Every assertion runs inside BEGIN; ... ROLLBACK;. nextval is
# non-transactional, so a sequence advances by one: harmless, and exactly what
# proves the sequence grant was needed and present.
# ===========================================================================
set -u

PASSED=0
FAILED=0
SKIPPED=0

pw_for() {
    case $1 in
        crm_svc)                     printf '%s' "$CRM_DB_PASSWORD" ;;
        allocation_key_svc)          printf '%s' "$ALLOCATION_KEY_DB_PASSWORD" ;;
        simulation_key_svc)          printf '%s' "$SIMULATION_KEY_DB_PASSWORD" ;;
        news_board_svc)              printf '%s' "$NEWS_BOARD_DB_PASSWORD" ;;
        billing_svc)                 printf '%s' "$BILLING_DB_PASSWORD" ;;
        administrative_document_svc) printf '%s' "$ADMINISTRATIVE_DOCUMENT_DB_PASSWORD" ;;
        notification_dispatch_svc)   printf '%s' "$NOTIFICATION_DISPATCH_DB_PASSWORD" ;;
        *) printf '' ;;
    esac
}

# check <role> <label>  — SQL on stdin, must succeed.
# On failure the psql output is printed: "permission denied for sequence
# audit_log_id_seq" tells you exactly which line to add to 30-crm-grants.sql.
check() {
    role=$1; label=$2
    pw=$(pw_for "$role")
    if out=$(PGPASSWORD="$pw" psql --no-psqlrc -q -v ON_ERROR_STOP=1 \
        -U "$role" -d crm_db -f - 2>&1); then
        PASSED=$((PASSED + 1))
        printf '  ok    %s\n' "$label"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s\n' "$label"
        printf '%s\n' "$out" | sed 's/^/          /'
    fi
}

crm_table_exists() {
    [ "$(psql --no-psqlrc -tAq -d crm_db -c "SELECT to_regclass('public.$1') IS NOT NULL" 2>/dev/null)" = "t" ]
}

skip() {
    SKIPPED=$((SKIPPED + 1))
    printf '  skip  %s\n' "$1"
}

# A missing table is a FAILURE, not a skip — but it is a different failure from a
# missing grant, and saying so saves the next person a wrong diagnosis.
absent() {
    FAILED=$((FAILED + 1))
    printf '  FAIL  public.%s does not exist in crm_db\n' "$1"
    printf '          Either optimce-migrator has not run against this database yet\n'
    printf '          (fresh deploy: run the migration profile, then re-run postgres-init),\n'
    printf '          or a restore is incomplete. It is NOT a grant problem.\n'
}

AUDIT_WRITERS='allocation_key_svc simulation_key_svc news_board_svc billing_svc administrative_document_svc'
NOTIFIERS='news_board_svc billing_svc administrative_document_svc'

# ---------------------------------------------------------------------------
echo
echo 'audit_log INSERT + audit_log_id_seq USAGE — all five annexe roles'
echo '  (id_community is nullable, so this ALWAYS inserts exactly one row and'
echo '   therefore ALWAYS calls nextval — the sequence grant is really exercised,'
echo '   not skipped because a lookup happened to return nothing.)'
if crm_table_exists audit_log; then
    for role in $AUDIT_WRITERS; do
        check "$role" "$role -> audit_log" <<'SQL'
BEGIN;
INSERT INTO audit_log (id_community, action, source, entity_type, entity_id, payload)
VALUES (NULL, 'verify.grant', 'verify', 'verify', '0', '{}'::jsonb);
ROLLBACK;
SQL
    done
else
    absent audit_log
fi

# ---------------------------------------------------------------------------
echo
echo 'allocation_key -> iteration -> consumer cascade — allocation_key_svc'
echo '  (one ORM flush inserts all three, so granting only allocation_key fails'
echo '   on the children. This ALSO proves the GENERATED ALWAYS AS IDENTITY'
echo '   assumption in 30-crm-grants.sql: no sequence grant was issued for these'
echo '   three, and if that assumption were wrong this is where it breaks.'
echo '   Needs at least one community row — it is the one check that can fail'
echo '   for a data reason rather than a grant reason.)'
check allocation_key_svc 'allocation_key_svc -> allocation_key/iteration/consumer' <<'SQL'
BEGIN;
WITH c AS (SELECT id FROM community ORDER BY id LIMIT 1),
     k AS (INSERT INTO allocation_key (name, description, id_community)
           SELECT '_verify', '_verify', id FROM c
           RETURNING id, id_community),
     i AS (INSERT INTO iteration (number, energy_allocated_percentage, id_key, id_community)
           SELECT 1, 100.0, id, id_community FROM k
           RETURNING id, id_community)
INSERT INTO consumer (name, energy_allocated_percentage, id_iteration, id_community)
SELECT '_verify', 100.0, id, id_community FROM i;
-- Without this, an empty `community` table makes every INSERT above affect zero
-- rows, the statements all "succeed", and the check passes having proved nothing.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM consumer WHERE name = '_verify') THEN
    RAISE EXCEPTION 'nothing was inserted: crm_db has no community row, so this grant was never exercised';
  END IF;
END $$;
ROLLBACK;
SQL

# ---------------------------------------------------------------------------
# Guarded, exactly like the matching block in 30-crm-grants.sql: this production
# line's CRM schema has no notification tables yet. When an optimce-migrator
# release adds them, the grants and these assertions light up together.
echo
echo 'notification / outbound_message INSERT — the producers'
if crm_table_exists notification && crm_table_exists outbound_message; then
    for role in $NOTIFIERS; do
        check "$role" "$role -> notification" <<'SQL'
BEGIN;
WITH src AS (SELECT id FROM app_user ORDER BY id LIMIT 1)
INSERT INTO notification (id_community, id_user, type, data)
SELECT NULL, id, 'verify.grant', '{}'::jsonb FROM src;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM notification WHERE type = 'verify.grant') THEN
    RAISE EXCEPTION 'nothing was inserted: crm_db has no app_user row, so this grant was never exercised';
  END IF;
END $$;
ROLLBACK;
SQL
        check "$role" "$role -> outbound_message" <<'SQL'
BEGIN;
INSERT INTO outbound_message
    (id_notification, id_community, channel, recipient, type, category, data, dedupe_key)
VALUES
    (NULL, NULL, 2, 'verify@example.invalid', 'verify.grant', 1, '{}'::jsonb,
     'verify-' || gen_random_uuid());
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM outbound_message WHERE type = 'verify.grant') THEN
    RAISE EXCEPTION 'nothing was inserted, so this grant was never exercised';
  END IF;
END $$;
ROLLBACK;
SQL
    done
else
    skip 'not in this schema — no notification tables in crm_db'
fi

# ---------------------------------------------------------------------------
echo
echo 'notification-dispatch: the claim loop and the bounce record'
echo '  (SELECT ... FOR UPDATE SKIP LOCKED requires the UPDATE privilege in its'
echo '   own right — a plain SELECT grant is not enough, and the failure would'
echo '   otherwise appear only when a real message needed sending.)'
if crm_table_exists outbound_message; then
    check notification_dispatch_svc 'notification_dispatch_svc -> claim outbound_message' <<'SQL'
BEGIN;
SELECT id FROM outbound_message
 WHERE status = 1 AND scheduled_for <= now()
 ORDER BY scheduled_for
 FOR UPDATE SKIP LOCKED
 LIMIT 1;
UPDATE outbound_message SET status = status WHERE id = -1;
ROLLBACK;
SQL
else
    skip 'claim loop — public.outbound_message not in this schema'
fi

if crm_table_exists email_suppression; then
    check notification_dispatch_svc 'notification_dispatch_svc -> email_suppression' <<'SQL'
BEGIN;
INSERT INTO email_suppression (email, reason, detail)
VALUES ('verify@example.invalid', 4, 'grant verification')
ON CONFLICT (email) DO NOTHING;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM email_suppression WHERE email = 'verify@example.invalid') THEN
    RAISE EXCEPTION 'nothing was inserted, so this grant was never exercised';
  END IF;
END $$;
ROLLBACK;
SQL
else
    skip 'bounce record — public.email_suppression not in this schema'
fi

# ---------------------------------------------------------------------------
echo
printf 'positive writes: %s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
if [ "$FAILED" -ne 0 ]; then
    echo 'A GRANTED WRITE DOES NOT WORK. In the running app this failure is'
    echo 'SILENT — the API returns 200 and the row simply never appears.'
    exit 1
fi
echo 'every granted CRM write lands.'
exit 0
