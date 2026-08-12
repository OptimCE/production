-- ===========================================================================
-- Six logical databases in one instance — NOT one database with six schemas.
--
-- Every annexe service documents "cross-DB references are plain columns, never
-- foreign keys". Separate databases are what currently enforce that by physics.
-- Merge into one database with per-service schemas and someone eventually adds
-- a real FK across a service boundary, and the separation rots silently. Only
-- the host and the user part of each DSN change; nothing else moves.
--
-- `keycloak` is deliberately absent: it stays on its own instance (compose
-- service `keycloak-db`). See postgres/README.md.
--
-- LOCALE NOTE. The CREATE DATABASE below is bare, so every database inherits
-- template1's encoding, collation and locale provider. That is correct only
-- while the source instances all match. DATABASE_CONSOLIDATION.md §0.2 captures
-- them before the migration; if they differ, add explicit ENCODING /
-- LC_COLLATE / LC_CTYPE / LOCALE_PROVIDER here BEFORE the first run. A
-- collation mismatch does not error — it silently changes index ordering and
-- the result of every range scan and ORDER BY.
-- ===========================================================================
\set ON_ERROR_STOP on

-- CREATE DATABASE cannot run inside DO or a transaction block. Generate the
-- statements and let \gexec execute each one standalone. Produces zero rows —
-- and therefore does nothing — on every run after the first.
-- `notification_dispatch_svc` is absent on purpose: it owns no database. Its
-- queue (outbound_message) lives in the CRM schema so that a producer's enqueue
-- rides on that producer's own transaction.
SELECT format('CREATE DATABASE %I OWNER %I', d.name, d.owner)
  FROM (VALUES
    ('crm_db',                        'crm_svc'),
    ('allocation_key_local',          'allocation_key_svc'),
    ('simulation_key_local',          'simulation_key_svc'),
    ('news_board_local',              'news_board_svc'),
    ('billing_local',                 'billing_svc'),
    ('administrative_document_local', 'administrative_document_svc')
  ) AS d(name, owner)
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = d.name)
\gexec

-- PUBLIC holds CONNECT on every new database by default. THIS is the line that
-- actually delivers the isolation; without it the roles above are decoration
-- and any role could open any database.
REVOKE CONNECT ON DATABASE
    crm_db,
    allocation_key_local,
    simulation_key_local,
    news_board_local,
    billing_local,
    administrative_document_local
  FROM PUBLIC;

-- template1 too, so a seventh database created here later inherits "PUBLIC
-- cannot connect" instead of relying on someone remembering this file.
--
-- `postgres` (the maintenance database) is deliberately NOT revoked: pg_database
-- and pg_roles are readable from any database anyway so it buys nothing, and it
-- would break the default connection target of every GUI client.
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

-- Own database: exactly one role each.
GRANT CONNECT ON DATABASE allocation_key_local          TO allocation_key_svc;
GRANT CONNECT ON DATABASE simulation_key_local          TO simulation_key_svc;
GRANT CONNECT ON DATABASE news_board_local              TO news_board_svc;
GRANT CONNECT ON DATABASE billing_local                 TO billing_svc;
GRANT CONNECT ON DATABASE administrative_document_local TO administrative_document_svc;

-- crm_db: its owner, plus every consumer of the read-only CRM port — including
-- notification_dispatch_svc, whose ONLY database this is. What each of them may
-- actually DO once connected is 30-crm-grants.sql.
GRANT CONNECT ON DATABASE crm_db TO
    crm_svc,
    allocation_key_svc,
    simulation_key_svc,
    news_board_svc,
    billing_svc,
    administrative_document_svc,
    notification_dispatch_svc;
