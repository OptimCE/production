# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **administrative-document** (API + worker) and **notification-dispatch**
  (worker). `administrative_document_local` is a sixth logical database inside
  the existing instance — no new database container. notification-dispatch owns
  no database: its `outbound_message` queue lives in the CRM schema so a
  producer's enqueue rides on that producer's own transaction, so it gets a role
  (`notification_dispatch_svc`) and nothing else.
  - **Prerequisite**: both need CRM tables (`notification`, `outbound_message`,
    `email_suppression`, `notification_preference`) that this deployment's CRM
    does not yet have. They ship as CRM migration **version 9** and arrive via the
    `migration` profile. See
    [DATABASE_CONSOLIDATION.md](DATABASE_CONSOLIDATION.md) §9.1 — starting either
    service before then is a silent failure, not a loud one.
  - New `.env` variables: two role passwords plus an email-delivery block
    (`EMAIL_TRANSPORT`, the `SMTP_*` set, the `BREVO_*` set,
    `DISPATCH_POLL_INTERVAL_SECONDS`).
  - The 11 administrative-document template families are vendored under
    `docker-compose/document-templates/` and seeded into MinIO by `minio-init`.
    Its Walloon reference data is **not** loaded — it is applied once as a
    migration rather than on every start, see §9.8. Until then the service runs
    with an empty deadline-rule and template catalogue.
- `docker-compose/schemas/administrative_document_local.sql`.

### Fixed

- **The vendored CRM baseline was 149 lines behind the monorepo.**
  `docker-compose/schemas/crm_db.sql` was missing 9 tables (`audit_log`,
  `notification`, `outbound_message`, `email_suppression`,
  `notification_preference`, `municipality`, `municipality_postal_code`,
  `sharing_operation_municipality`, `community_subscription`), 6 columns
  (`community.regulator` + the bank/legal set, `app_user.locale`), 14 indexes and
  2 triggers. This is inert for a running deployment — the baseline is applied
  only to a database with no tables, and `optimce-migrator` remains the only
  thing that moves the live CRM forward — but a rebuild from an empty volume used
  to produce a CRM nine tables short of what the images expect.
- Corrected DATABASE_CONSOLIDATION.md §5 on deferred constraint triggers. A full
  `pg_restore` of `administrative_document_local` is safe with or without
  `--single-transaction`, because `pg_dump` emits triggers after the data; only a
  `--data-only` restore into an already-schema'd database trips them, and it
  fails with a misleading `relation "status_event" does not exist`. Rehearsed
  rather than assumed.

### Added (Keycloak)

- Realm internationalization in `keycloak/realm/prod-config.template.json`:
  `internationalizationEnabled`, `supportedLocales` (`fr`, `nl`, `de`, `en`) and
  `defaultLocale`. The `optimce` keycloakify theme ships translations for exactly
  those four, but without these realm settings the language selector never renders
  and none of it is reachable.
  - **The realm import does not apply to an existing realm.** `--import-realm`
    imports only when the realm is absent, so on a running deployment these — and
    `loginTheme` before them — must be set by hand once. See
    [DATABASE_CONSOLIDATION.md](DATABASE_CONSOLIDATION.md) §10.

### Fixed (deployment ↔ migrator)

- **`optimce-migrator` now receives a URL for every database it manages.** The image's
  `database.config` had grown a second entry (`billing`), but this deployment supplied
  only `OPTIMCE_CRM_DATABASE_URL`. The migrator resolves its whole config up front and
  raises on the first missing variable, so the next migration run would have exited 1
  with a "configuration error" that names an environment variable and not this repo.
  The block now passes all three URLs — CRM, billing and administrative-document — each
  as that database's owning role, with a comment explaining why a missing one is fatal.

### Removed

- The seed step in `postgres/provision/provision.sh`, and with it `SKIP_SEEDS`.
  The monorepo re-applies `/seeds/<db>/*.sql` on every `up`, which is right for
  development and wrong here: in production what a database contains must be a
  function of its migration history, not of how many times it has been restarted.
  Reference data is applied once, as a migration. This is the only intentional
  behavioural difference between the two copies of the script.

### Changed

- **Database consolidation.** The five application databases (`crm_db`,
  `allocation_key_local`, `simulation_key_local`, `news_board_local`,
  `billing_local`) now live in a single `postgres` instance instead of five, each
  owned by its own login role. `keycloak-db` deliberately remains separate.
  Applying this to a running deployment is a scheduled maintenance window with a
  documented procedure — see
  [DATABASE_CONSOLIDATION.md](DATABASE_CONSOLIDATION.md).
- **Least privilege.** No service connects as the `postgres` superuser any more.
  Each connects as `<service>_svc`; `PUBLIC` cannot `CONNECT` to any application
  database. What an annexe may write to `crm_db` is now enforced by the database
  rather than by convention.
- The five `*_DB_PASSWORD` variables change meaning: each is now one login role's
  password rather than an instance superuser's. `KEYCLOAK_DB_PASSWORD` is
  unchanged.
- The `postgres:18-alpine` image is now digest-pinned.
- Backups: the six per-database jobs are replaced by `db-backup` (all five
  databases plus `pg_dumpall --globals-only`) and the unchanged
  `keycloak-db-backup`. Filenames keep their existing pattern.
- The vendored schemas moved from `<service>-db/docker-entrypoint-initdb.d/init.sql`
  to `docker-compose/schemas/<database>.sql`. They are disaster-recovery baselines,
  applied only to a database with no tables.

### Added

- `docker-compose/postgres/` — the single provisioning path (`provision.sh` plus
  its SQL), which converges roles, passwords, databases, ownership, `CONNECT`
  ACLs and the CRM grant matrix on every start, and the two verification scripts
  that prove the result.
- `./docker-stack.sh verify` — runs the isolation and positive-write proofs.
  `positive-writes.sh` is not optional: a missing `audit_log` grant is silent at
  runtime, so the API returns 200 and the audit row simply never appears.
- `POSTGRES_SUPERUSER_PASSWORD` in `docker-compose/.env`.
- `.gitattributes` pinning the provisioning scripts and SQL to LF endings.

### Notes

- `optimce-migrator` now runs as `crm_svc`. **Re-run `postgres-init` after any
  migrator run** — tables it creates arrive ungranted until the grants converge.
- The six pre-consolidation volumes are retained but unreferenced, as the
  rollback path. Do not run `docker compose down -v` or `docker volume prune`
  while the rollback window is open.
