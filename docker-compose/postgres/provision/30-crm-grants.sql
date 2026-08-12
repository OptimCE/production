-- ===========================================================================
-- The CRM grant matrix. Connected to crm_db, run on EVERY start.
--
-- This is the file that turns the "read-only CRM port" every annexe documents
-- into something the database enforces, rather than something the code
-- promises. Before consolidation every service reached crm_db as the superuser.
--
-- Six roles reach crm_db without owning it:
--
--   allocation_key_svc          SELECT + audit + its own domain cascade
--   simulation_key_svc          SELECT + audit
--   news_board_svc              SELECT + audit + notifications
--   billing_svc                 SELECT + audit + notifications
--   administrative_document_svc SELECT + audit + notifications
--   notification_dispatch_svc   SELECT + the delivery loop, and nothing else
--
-- notification_dispatch_svc is the odd one out in both directions: it owns no
-- database at all, and it is the only role holding an UPDATE anywhere in crm_db.
-- ===========================================================================
\set ON_ERROR_STOP on

-- MUST run with current_user = crm_svc, for two separate reasons:
--
--   * ALTER DEFAULT PRIVILEGES with no FOR ROLE applies only to objects created
--     by the CURRENT role. Every CRM table is created by crm_svc — restored as
--     crm_svc, migrated by optimce-migrator as crm_svc, and written by
--     crm-backend as crm_svc. Attach the defaults to `postgres` instead and the
--     table tomorrow's migration adds arrives ungranted.
--
--   * "Ungranted" is SILENT here. The annexes' audit and notification writes run
--     inside a SAVEPOINT under a blanket `except Exception`, so a missing grant
--     does not raise: the business transaction commits, the API returns 200, and
--     the audit trail and every email vanish with only a log line. Verify with
--     postgres/verify/positive-writes.sh, never by watching for 500s.
SET ROLE crm_svc;

-- ---------------------------------------------------------------------------
-- Reads — blunt, deliberately.
--
-- The set of CRM tables an annexe SELECTs from changes with the code, and a
-- missing SELECT grant is a runtime failure in production. Blanket SELECT still
-- blocks every write, which is the actual risk this file exists to close.
--
-- USAGE ON SCHEMA public is load-bearing, not hygiene: crm_db's baseline schema
-- opens with DROP SCHEMA public CASCADE + CREATE SCHEMA public
-- (schemas/crm_db.sql:1), and a user-created schema carries NO privileges for
-- PUBLIC (unlike the historic initdb-created `public`). Without this line every
-- annexe fails its first query with "permission denied for schema public".
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;

-- Not retroactive is the whole reason this runs on EVERY start rather than once:
-- it covers tables that already existed when a role was added, and tables an
-- optimce-migrator release added between two `up`s.
--
-- Caveat worth knowing when reading the log: issued as crm_svc, this statement
-- emits a WARNING — not an error — for any table crm_svc does not own. A
-- "no privileges were granted for ..." line here means the migrator ran as
-- `postgres`; see 91-reown-crm.sql.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;

-- ---------------------------------------------------------------------------
-- Writes — narrow, one row per verified call site, and every one of them
-- GUARDED on the table existing. That guard is not defensive programming; it is
-- forced by who owns this schema.
--
-- NOT ONE of the tables below is guaranteed present. schemas/crm_db.sql is the
-- v0 baseline for a FRESH database and now carries all of them, but the LIVE
-- production crm_db is whatever ghcr.io/optimce/migrator:main has made it —
-- audit_log arrived at schema_version 5, and the notification-delivery tables
-- have not reached this deployment line at all yet. The migrator is an external
-- image released independently of this repo.
--
-- A bare `GRANT INSERT ON audit_log` therefore aborts psql, trips `set -e` in
-- provision.sh, makes postgres-init exit non-zero, and leaves EVERY service
-- refusing to start behind `service_completed_successfully` — on any crm_db the
-- migrator has not populated yet. Hard grants would also deadlock disaster
-- recovery, because the tables cannot exist before the stack that creates them
-- can start.
--
-- So provisioning CONVERGES and verification ASSERTS. This file grants what is
-- there and says loudly what is not; postgres/verify/positive-writes.sh is the
-- hard gate that fails if a grant an annexe actually needs is missing.
--
-- AFTER ANY optimce-migrator RUN, RE-RUN postgres-init. New tables arrive
-- ungranted until it does. `docker-stack.sh restart` does it; so does
-- `docker compose --profile backend run --rm postgres-init`.
--
--   expected = true  -> absent means "the migrator has not run here yet",
--                       and anything else is a real problem. RAISE WARNING.
--   expected = false -> not on this release line yet. RAISE NOTICE. The grant
--                       lights up by itself the first time the table appears.
--
-- The sequence column is NULL where the primary key is GENERATED ALWAYS AS
-- IDENTITY (or, for email_suppression, the address itself): an identity column's
-- nextval is evaluated internally with the sequence ACL check skipped, so INSERT
-- on the table is sufficient. audit_log, notification and outbound_message are
-- BIGSERIAL — a plain `nextval(...)` default that DOES go through the normal ACL
-- check, so INSERT alone yields "permission denied for sequence ..." at first
-- write and never at deploy. positive-writes.sh proves that asymmetry rather
-- than assuming it.
--
-- Call sites, for the record:
--   audit_log                            core/audit_log/service.py, all five annexes
--   allocation_key, iteration, consumer  one ORM flush cascades into all three
--                                        (allocation-key-generation only)
--   notification, outbound_message       core/notifications/, producers only
--   outbound_message UPDATE              notification-dispatch's claim loop:
--                                        SELECT ... FOR UPDATE SKIP LOCKED needs
--                                        UPDATE in its own right, and the same
--                                        grant covers the CLAIMED/SENT/FAILED/
--                                        SUPPRESSED transitions and the reaper
--   email_suppression INSERT             notification-dispatch's bounce record
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    ANNEXES   CONSTANT text := 'allocation_key_svc, simulation_key_svc, news_board_svc, billing_svc, administrative_document_svc';
    PRODUCERS CONSTANT text := 'news_board_svc, billing_svc, administrative_document_svc';
    DISPATCH  CONSTANT text := 'notification_dispatch_svc';
    g                  record;
    missing            text[] := '{}';
BEGIN
    FOR g IN SELECT * FROM (VALUES
            ('audit_log',         'audit_log_id_seq',        'INSERT', ANNEXES,              true),
            ('allocation_key',    NULL,                      'INSERT', 'allocation_key_svc', true),
            ('iteration',         NULL,                      'INSERT', 'allocation_key_svc', true),
            ('consumer',          NULL,                      'INSERT', 'allocation_key_svc', true),
            ('notification',      'notification_id_seq',     'INSERT', PRODUCERS,            false),
            ('outbound_message',  'outbound_message_id_seq', 'INSERT', PRODUCERS,            false),
            ('outbound_message',  NULL,                      'UPDATE', DISPATCH,             false),
            ('email_suppression', NULL,                      'INSERT', DISPATCH,             false)
        ) AS v(tbl, seq, priv, grantees, expected)
    LOOP
        IF to_regclass('public.' || g.tbl) IS NULL THEN
            IF g.expected THEN
                -- One entry per table, not per grant: outbound_message appears
                -- on two rows and must not be reported twice.
                IF NOT (g.tbl = ANY (missing)) THEN
                    missing := missing || g.tbl;
                END IF;
            ELSE
                RAISE NOTICE '[30-crm-grants] public.% not on this release line — % grant skipped', g.tbl, g.priv;
            END IF;
            CONTINUE;
        END IF;

        EXECUTE format('GRANT %s ON public.%I TO %s', g.priv, g.tbl, g.grantees);

        IF g.seq IS NOT NULL AND to_regclass('public.' || g.seq) IS NOT NULL THEN
            EXECUTE format('GRANT USAGE ON SEQUENCE public.%I TO %s', g.seq, g.grantees);
        END IF;
    END LOOP;

    IF array_length(missing, 1) IS NOT NULL THEN
        RAISE WARNING '[30-crm-grants] expected CRM table(s) absent: %. Normal ONLY on a crm_db that optimce-migrator has not populated yet — run the migration profile, then re-run postgres-init. On a restored production database this means the restore is incomplete: STOP.',
            array_to_string(missing, ', ');
    END IF;
END $$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- What is deliberately NOT granted, because that is the point:
--
--   * No DELETE on anything. No service issues one against crm_db.
--   * No UPDATE for any annexe, on any table. The single UPDATE in the whole
--     matrix is notification_dispatch_svc on outbound_message.
--   * notification_dispatch_svc never inserts a notification, never inserts an
--     outbound_message, and never writes an audit row. It owns the delivery
--     loop and the bounce record, nothing else.
--   * No INSERT on community, app_user, member, meter, document,
--     sharing_operation, municipality, ... for anyone but crm_svc.
--   * No CREATE on schema public for anyone but crm_svc — no annexe can run DDL
--     against the CRM.
--   * No role for keycloak: it is on a separate instance and cannot resolve a
--     route to this one.
--
-- TEMPORARY stays granted to PUBLIC (the default). It is reachable only by a
-- role that already has CONNECT, and a temp table in a private temp schema is
-- not a boundary violation.
-- ---------------------------------------------------------------------------
