-- ===========================================================================
-- RECOVERY TOOL. Not run by provision.sh. Run it deliberately, as `postgres`,
-- connected to crm_db:
--
--     docker compose -f docker-compose/docker-compose.yml --env-file docker-compose/.env \
--       exec postgres psql -U postgres -d crm_db -f /dev/stdin \
--       < docker-compose/postgres/provision/91-reown-crm.sql
--
-- Then re-run provisioning so the grants converge:
--
--     docker compose -f docker-compose/docker-compose.yml --env-file docker-compose/.env \
--       run --rm postgres-init
--
-- WHY IT EXISTS
--
-- crm_db's schema is applied by ghcr.io/optimce/migrator:main, an external image
-- this repo does not build. The compose file runs it as `crm_svc` so that every
-- object it creates is owned by crm_svc, which is what makes
-- `ALTER DEFAULT PRIVILEGES` in 30-crm-grants.sql cover tomorrow's tables.
--
-- If a migrator release ever turns out to need superuser and has to be run as
-- `postgres`, the objects it creates are owned by `postgres` instead. The
-- consequences are quiet rather than loud:
--
--   * ALTER DEFAULT PRIVILEGES FOR crm_svc does not apply to them, so the
--     annexes get no SELECT on any new table.
--   * `GRANT SELECT ON ALL TABLES` issued as crm_svc emits a WARNING for them,
--     not an error — provisioning still exits 0.
--   * crm-backend, connecting as crm_svc, cannot ALTER or DROP them later.
--
-- This file puts ownership back. It is idempotent and a no-op when everything is
-- already correct.
-- ===========================================================================
\set ON_ERROR_STOP on

DO $$
DECLARE
    r       record;
    moved   int := 0;
BEGIN
    -- Tables, partitioned tables, sequences, views and materialised views.
    -- ALTER TABLE is the correct verb for all of them in PostgreSQL.
    FOR r IN
        SELECT c.oid::regclass AS obj
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
           AND c.relowner <> 'crm_svc'::regrole
         ORDER BY 1
    LOOP
        RAISE NOTICE '[91-reown] ALTER TABLE % OWNER TO crm_svc', r.obj;
        EXECUTE format('ALTER TABLE %s OWNER TO crm_svc', r.obj);
        moved := moved + 1;
    END LOOP;

    -- Functions and procedures — the modtime trigger function lives here.
    FOR r IN
        SELECT p.oid::regprocedure AS obj
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proowner <> 'crm_svc'::regrole
         ORDER BY 1
    LOOP
        RAISE NOTICE '[91-reown] ALTER ROUTINE % OWNER TO crm_svc', r.obj;
        EXECUTE format('ALTER ROUTINE %s OWNER TO crm_svc', r.obj);
        moved := moved + 1;
    END LOOP;

    -- Composite / enum / domain types declared outside a table.
    FOR r IN
        SELECT t.oid::regtype AS obj
          FROM pg_type t
          JOIN pg_namespace n ON n.oid = t.typnamespace
         WHERE n.nspname = 'public'
           AND t.typowner <> 'crm_svc'::regrole
           AND t.typtype IN ('c', 'e', 'd')
           AND NOT EXISTS (SELECT 1 FROM pg_class c
                            WHERE c.reltype = t.oid AND c.relkind <> 'c')
         ORDER BY 1
    LOOP
        RAISE NOTICE '[91-reown] ALTER TYPE % OWNER TO crm_svc', r.obj;
        EXECUTE format('ALTER TYPE %s OWNER TO crm_svc', r.obj);
        moved := moved + 1;
    END LOOP;

    IF moved = 0 THEN
        RAISE NOTICE '[91-reown] nothing to do — crm_svc already owns every object in public';
    ELSE
        RAISE NOTICE '[91-reown] % object(s) reassigned. Re-run postgres-init so the grants converge.', moved;
    END IF;
END $$;

-- The schema itself. Covered by 20-schema-owner.sql on every provisioning run,
-- repeated here so this file is complete on its own.
ALTER SCHEMA public OWNER TO crm_svc;
