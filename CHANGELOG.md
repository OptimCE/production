# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (realtime SSE and maps)

- **`redis`** — the realtime ticket store and pub/sub bus, on a new `redis` network
  joined by `crm-backend` and the nine publishers and nothing else. No volume, no
  AOF, no RDB: every key is a <=30 s ticket or an in-flight PUBLISH, so losing
  everything on restart is correct. Digest-pinned, like `postgres` and `keycloak`,
  because it holds a live credential store.
  - `REDIS_PASSWORD` is not hygiene. A ticket carries the exact channel list its
    holder may subscribe to, so an unauthenticated Redis on that network is an
    impersonation oracle. Use URL-safe characters — the value is interpolated into
    `REALTIME_REDIS_URL` in userinfo position, so `@ : / # ?` corrupt the DSN and
    `$` is eaten by compose.
  - It is passed as an explicit `environment:` entry rather than through
    `env_file: .env`, which is what the development stack does. `env_file` here
    would hand the ticket store all seven database role passwords, the superuser
    password, the MinIO keys and the SMTP/Brevo credentials.
  - `crm-backend` gates on `service_started`, **not** `service_healthy` as the
    development stack does. Realtime must degrade to polling; gating on health
    would turn an unreachable ticket store into "the entire CRM API never starts".
- **`REALTIME_ENABLED` ships `false`.** With it false the ticket endpoint 503s,
  crm-backend opens no Redis connection, every producer's `emit()` is a no-op, and
  the SPA polls exactly as before. That is both the rollout and the rollback, and
  it is why this can land outside a maintenance window. Switching it on is a
  documented, separately reversible step — see
  [`docs/runbooks/realtime-sse.md`](docs/runbooks/realtime-sse.md).
- `location = ${WEB_REALTIME_PATH}` in both nginx templates, plus the
  `upstream crm-backend` it proxies to. Exact match, `proxy_pass` with no URI
  path, and the five gateway-trust headers cleared to empty so nginx drops them:
  crm-backend authenticates nothing and trusts `x-user-id`, so a prefix match or a
  trailing slash would expose the whole API unauthenticated.
  - **The reverse proxy now refuses to start unless `crm-backend` resolves.**
    nginx resolves `upstream` server names at config load. Start `backend` before
    `frontend`, as `docker-stack.sh` already does.
  - The HTTPS template's two port-80 blocks gained a ticket-preserving 301 that
    keeps `?t=` and stays out of the access log. It is present on the `s3.` vhost
    too, where it is inert — the runbook's bring-up check counts occurrences.
- `realtimeUrl` and `map.styleUrl` in `crm-frontend-config/config.template.json`,
  both rendered from the same `.env` values as the nginx location, so the client
  and the proxy cannot drift into a permanent silent fallback. `realtimeUrl`
  deliberately falls outside `keycloak.urlPattern`: EventSource cannot carry a
  bearer token, so an interceptor attaching one would be misleading.
- The `GEOCODING_*` block on `crm-backend`, shipping `GEOCODING_MODE=LOCAL`.
  REMOTE is outbound traffic to two third-party geocoders carrying member address
  strings, and is reached only from the admin-only `POST /geocoding/backfill` —
  see [`docs/runbooks/map-views.md`](docs/runbooks/map-views.md).
- `WEB_REALTIME_PATH`, `WEB_MAP_STYLE_URL`, `CRM_BACKEND_UPSTREAM`,
  `CRM_BACKEND_PROTOCOL`, the `REALTIME_*` ceilings and the `GEOCODING_*` block in
  `docker-compose/.env.example`. The upstream pair lives in `.env` rather than
  inline on the service, because this deployment's `nginx-config` reads its
  upstreams through `env_file`.

### Added (migrations)

- **`./docker-stack.sh migrate`** (and `docker-stack.bat migrate`), with
  `--dry-run` and `--no-pull`. It pulls `optimce-migrator`, runs it, and **always**
  re-runs `postgres-init` afterwards — including after a failure, because each
  migration commits in its own transaction and tables that landed arrive
  ungranted, which is silent at runtime rather than loud. This packages
  [DATABASE_CONSOLIDATION.md](DATABASE_CONSOLIDATION.md) §9.1.
- **`optimce-migrator` now receives six database URLs, not three.** The image has
  grown `migrations/allocation-key`, `migrations/simulation-key` and
  `migrations/news-board`. `allocation_key_local` and `simulation_key_local` each
  owe a migration the deployed images already expect — a CRM-sourced generation or
  simulation writes `source`, `id_sharing_operation`, `period_start`, `period_end`
  and `data_warnings`, and until now there was no mechanism to add them to a live
  database. `news-board` carries an empty manifest and is registered ahead of need,
  so its first migration is a one-repo change.
  - **Pull this repo before pulling the image.** The migrator resolves its whole
    config up front and raises on the first missing variable; reversed, the run
    exits 1 naming an environment variable and not the file it belongs in. It
    fails before opening a connection, so the blast radius is a failed one-shot.
  - `ALLOCATION_KEY_DB_PASSWORD`, `SIMULATION_KEY_DB_PASSWORD` and
    `NEWS_BOARD_DB_PASSWORD` are now consumed twice: by their own service, and by
    the migrator connecting as the same owning role. No new secret.

### Fixed

- **Every upload larger than 1 MB was 413'd by nginx itself.** Neither template
  set `client_max_body_size`, so nginx's implicit 1 MB default applied — and the
  refusal is generated by nginx, as a bare HTML page that never reaches the app,
  so it carries no `error_code` the frontend can turn into a message. Now 2 MB at
  server level and 50 MB inside `location /api/`, mirroring the annexes'
  `MAX_BODY_BYTES` / `UPLOAD_MAX_BODY_BYTES`.
- **The SPA fallback refused legitimate deep links.** It tested `$request_uri`,
  which carries the query string, so `?email=a@b.com` or
  `?ref=https%3A%2F%2Fpartner.be` looked like a file extension and returned 404.
  It now tests `$uri`.
- **The vendored baselines were behind the monorepo again.**
  `schemas/crm_db.sql` was missing the whole `address` geolocation block
  (`latitude`, `longitude`, `geo_precision`, `geo_source`, `geocoded_at`,
  `geocode_status`, both CHECK constraints and the partial queue index), so a
  rebuild from an empty volume produced a CRM on which every map query and the
  geocoding backfill fail at the SQL level. `allocation_key_local.sql` and
  `simulation_key_local.sql` were missing `generation.source` / `simulation.source`
  and their period columns, so every CRM-sourced run would have been rejected by a
  `NOT NULL` on `file_storage_key`. All six baselines now match their monorepo
  source exactly. Inert for a running deployment — these are applied only to a
  database with no relations.
  - The CRM baseline tracks `crm-backend/database_script/init.sql`, **not**
    `crm-backend/tests/sql/init.sql`. The latter is what the development stack
    mounts and it carries 72 fixture `INSERT`s plus eight sequence resets.
- `notification-dispatch` now receives `BREVO_SUPPRESSION_SYNC_INTERVAL_SECONDS`.
  Unset, it silently took the image default; Brevo reports bounces by webhook only
  and this service has no inbound HTTP surface by design, so this poll is the only
  path by which a hard bounce ever reaches `email_suppression`.
- `docker-stack.sh` / `.bat` now refuse to start the frontend profile when
  `crm-frontend-config/config.json` is missing or is a **directory**. Docker
  creates a missing single-file bind source as a directory, and the app then
  serves a blank page with nothing useful in any log. The obvious fix — a
  `depends_on` on `crm-frontend-config` — is not available: it lives in the `init`
  profile and compose rejects a `depends_on` target outside the enabled profiles,
  which would break `--profile frontend up -d` outright.

### Notes

- **A realtime failure is indistinguishable from a quiet system.** The pollers keep
  the UI correct when push is dead, so "nobody complained" is not evidence — three
  defects shipped upstream exactly this way. The check that can see it is the
  startup log line: every producer logs `Realtime disabled — <component> publishes
  nothing` or `Realtime publisher ready — …`. **An image that predates the feature
  logs neither, while its environment variables look perfectly correct.** That is
  this deployment's replacement for the development stack's `--build` discipline:
  here, compare image digests and read the log line.
- `REALTIME_MAX_CONNECTIONS` is capped at 500 rather than the image's 2000. Each
  live stream consumes two of nginx's `worker_connections` (client leg + upstream
  leg) and the stock nginx image allows 1024 per worker. Raise the two together or
  neither.
- The `sse` network is **declarative here, not load-bearing**: `reverse-proxy` and
  `crm-backend` already share `api-gateway` and `crm`, so removing it would not
  stop nginx resolving crm-backend. The property that is enforced is that
  `crm-frontend` shares no network with `crm-backend`.

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
