-- ===========================================================================
-- Make schema `public` DIRECTLY owned by the database's service role.
-- Runs as the superuser, once per database, on every start. Takes :owner.
--
-- Why this exists, when the role already owns the database:
--
-- On PG15+ `public` is owned by pg_database_owner, an implicit role whose only
-- member is the owner of the current database. So crm_svc CAN already drop and
-- recreate it — but only via inherited implicit membership, which is exactly the
-- kind of dependency that breaks silently and is miserable to diagnose (create
-- the role NOINHERIT and `DROP SCHEMA public` starts answering "must be owner of
-- schema public", with nothing pointing at the cause).
--
-- After this ALTER the role is the DIRECT owner and every subsequent operation
-- is an ordinary owner-acts-on-own-object check.
--
-- It is also what a `pg_restore --no-owner` run as the service role expects to
-- find: the dump does NOT carry the schema's ownership, only its contents. This
-- file supplies it, which is why provisioning pass 1 runs BEFORE the restore.
-- ===========================================================================
\set ON_ERROR_STOP on

ALTER SCHEMA public OWNER TO :"owner";

-- PUBLIC gets nothing on `public` here. Consumers of crm_db are granted USAGE
-- explicitly in 30-crm-grants.sql; the five *_local databases have exactly one
-- role and need no grant at all.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT  ALL ON SCHEMA public TO :"owner";
