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
  separate, reversible step.
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
    too, where it is inert — the template carries three `${WEB_REALTIME_PATH}`
    locations in total.
- `realtimeUrl` and `map.styleUrl` in `crm-frontend-config/config.template.json`,
  both rendered from the same `.env` values as the nginx location, so the client
  and the proxy cannot drift into a permanent silent fallback. `realtimeUrl`
  deliberately falls outside `keycloak.urlPattern`: EventSource cannot carry a
  bearer token, so an interceptor attaching one would be misleading.
- The `GEOCODING_*` block on `crm-backend`, shipping `GEOCODING_MODE=LOCAL`.
  REMOTE is outbound traffic to two third-party geocoders carrying member address
  strings, and is reached only from `POST /geocoding/backfill`, which is limited to
  the Keycloak user ids in the new `GEOCODING_BACKFILL_OPERATORS` (empty = nobody):
  the backfill geocodes every community's addresses, and any user can create a
  community and become its ADMIN.
- `WEB_REALTIME_PATH`, `WEB_MAP_STYLE_URL`, `CRM_BACKEND_UPSTREAM`,
  `CRM_BACKEND_PROTOCOL`, the `REALTIME_*` ceilings and the `GEOCODING_*` block in
  `docker-compose/.env.example`. The upstream pair lives in `.env` rather than
  inline on the service, because this deployment's `nginx-config` reads its
  upstreams through `env_file`.

### Added (the BeSt Address picker)

- **`best-address`** — the federal BeSt Address register (FPS BOSA), self-hosted in
  the `backend` profile on a new `best-address` network that `crm-backend` is the
  only member of. It backs the address picker (`GET /geocoding/suggest`) and the
  rooftop-precision pin a new meter gets at write time. Unlike the two regional
  geocoders this one is ours and on our own network, which is what makes it the one
  address lookup allowed on the inline write path.
  - **It costs ~1.7 GB resident**, on top of everything this host already runs.
    Confirm the headroom before the window. If it will not fit, blank
    `BEST_ADDRESS_URL` and set `GEOCODING_MODE=REMOTE` — you lose the picker, not
    the map.
  - **Digest-pinned, because the image *is* the dataset.** The address file is baked
    in and tagged `YYYY-WW` for the ISO week of the extract, so a `docker pull` is
    the data refresh and an unpinned tag means two hosts can silently sit weeks
    apart. Pinned to `2026-35@sha256:3711…`, byte-identical to the monorepo's pin.
  - Its healthcheck runs a **real `/addresses` query, with `curl`**. Not `/health`:
    the first read after a cold start measured **56 seconds** while Postgres pages
    the address table in, against 0.09 s once warm, and KrakenD's cap is 3000 ms —
    so a box answering `/health` is not ready in any useful sense. And not `wget`:
    the image does not ship one, so a `wget` probe can never pass and would leave
    the container permanently `unhealthy` while working perfectly.
  - **No `depends_on` from `crm-backend`.** Gating the whole CRM API on a ~45 s
    warm-up, to protect a feature that degrades to "no suggestions" on its own, is
    the wrong trade. The cost is that a `best-address` that never comes up is
    invisible unless you look.
  - `PGOPTIONS` must stay unset. The image splices it **unquoted** into
    `pg_ctl start -D $PGDATA $PGOPTIONS`, so a value becomes raw `pg_ctl` arguments
    and the container crash-loops in silence.
  - Attribution is required — the data is CC-BY 4.0: *Service public de Wallonie*,
    *Paradigm.Brussels*, *Digitaal Vlaanderen*.
- `BEST_ADDRESS_URL` and `BEST_ADDRESS_TIMEOUT_MS` on `crm-backend`, and in
  `docker-compose/.env.example`. The URL uses compose's `-` form, not `:-`, so it
  fills in only when the variable is **unset**: **blanking the value is the off
  switch, deleting the line is not.** Blank, the suggester is unbound and
  `GET /geocoding/suggest` answers `[]` rather than erroring — which is also how a
  misconfiguration hides, so check `docker compose ps best-address` before believing
  the picker is broken.
- **`.github/renovate.json`** — this repo had no `.github/` at all. It mirrors the
  monorepo's config (`config:recommended`, `group:allNonMajor`, `docker:pinDigests`)
  plus one rule that exists solely for the register: Renovate's default docker
  versioning reads `2026-35` as major 2026 with compatibility suffix 35 and would
  then only ever look for another `-35` tag, so **the weekly address refresh would
  silently never be offered** and the register would freeze at whatever week was
  pinned the day this landed.

### Added (migrations)

- **CRM migration 11 — house numbers become text, plus the BeSt link.**
  `address.number` widens from `INT` to `VARCHAR(32)` (a Belgian house number is
  `12A`, not 12 — the register returns `12-14`, `1/3`, `2/0001`), and `country`
  (ISO-3166-1 alpha-2, default `BE`) and `best_address_id` are added, with
  `chk_address_number_not_blank`, `chk_address_country`, the partial
  `idx_address_best_id`, and `idx_address_dedup` on `(postcode, street, number)` —
  which `addAddress` had been scanning sequentially on every write.
  - **crm-backend must be DOWN across this migration** — neither build is safe
    against the other's schema. The new image against the old schema fails *every*
    address read and write with `column address.country does not exist`, because
    the `Address` entity declares `country` and `best_address_id` and TypeORM
    selects entity columns by name. The old image against the new schema emits
    `"12"` instead of `12`, because it has no `houseNumberToString` transformer.
    Stop it, migrate, start it on the new image — which also clears the
    `ACCESS EXCLUSIVE` contention on `address`.
  - The type change is a **full table rewrite under `ACCESS EXCLUSIVE`** —
    sub-second at this volume, but a maintenance-window operation, not an online
    one.
  - **A green `./docker-stack.sh verify` is not evidence this landed.** It creates
    no relation, and a table-level `GRANT SELECT` already covers new columns, so
    every assertion would be green either way. Use `\d address`.
- **CRM migration 12 — `meter.ean` must be exactly 18 digits.** Adds
  `chk_meter_ean_18_digits`, but only after a guard has counted the rows that do not
  conform: if there are any it raises, the runner rolls the file and its
  `schema_version` row back together, and the CRM stays at 11 with nothing
  half-applied. **Expect that here** — the deployed crm-frontend enforced a 13-digit
  rule from 2026-06-08 until this release. A refusal blocks nothing: 11 is what the
  new crm-backend needs, and it already rejects a non-18-digit EAN on `POST /meters`.
  Online-safe (one scan of `meter` under a 5-second `lock_timeout`). Never get past it
  with `NOT VALID`: the offending meters would become read-only, and nothing can
  rewrite a meter's EAN. See `DEPLOYMENT_PLAN.md` Step 7 and
  `DATABASE_CONSOLIDATION.md` §9.13.
- `docker-compose/schemas/crm_db.sql` re-vendored from the monorepo, carrying the
  same address block and, since migration 12, `chk_meter_ean_18_digits` on `meter`.
  **Inert for the running deployment** — `postgres-init` applies
  a baseline only to a database with no relations — but it is what stops a
  rebuild-from-empty landing one migration short, permanently and with no way to
  notice.
- `docker-compose/krakend_config/administrative-document.json` added to
  `.gitignore`. It is generated by `administrative-document-doc-gen` like its five
  siblings, which were already ignored; it alone showed up as untracked noise.
- `docker-compose/krakend_config/swagger.yaml` removed from the repository and
  added to `.gitignore`. It is generated, not source: nothing here writes it —
  `swagger-doc-gen` writes `root.yaml` — and `krakend-builder.yaml` never reads
  it. A 380 KB stale snapshot committed by accident.

- **`./docker-stack.sh migrate`** (and `docker-stack.bat migrate`), with
  `--dry-run` and `--no-pull`. It pulls `optimce-migrator`, runs it, and **always**
  re-runs `postgres-init` afterwards — including after a failure, because each
  migration commits in its own transaction and tables that landed arrive
  ungranted, which is silent at runtime rather than loud.
- **`./docker-stack.sh survey-ean`** (and `docker-stack.bat survey-ean`), running
  `docker-compose/postgres/verify/ean-survey.sh`, ported unchanged from the monorepo:
  a read-only report of every stored EAN that is not 18 digits, as the superuser
  because it reads across databases. Exit 0 clean, 1 `meter.ean` offenders (listed,
  with samples), 2 a probe could not run. Run it before migration 12. Deliberately
  not part of `verify`, which one legacy row must not turn red.
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

### Added (annex catalogue switches)

- **`ANNEX_CATALOG_ENABLE` / `ANNEX_CATALOG_DISABLE`** on `crm-backend`, both empty.
  The annex catalogue is baked into the crm-backend image and shared by every
  deployment; an entry that ships `"defaultEnabled": false` stays hidden until named
  in ENABLE, and DISABLE hides an entry and wins over ENABLE. `live-data` ships that
  way and its service does not run here, so the empty defaults are right. A name the
  image's catalogue does not contain **refuses the boot**
  (`annexes_services:catalog_overrides`); the set actually served is logged once at
  boot as `annexes_services:catalog_loaded`. README's "Adding a new annex service"
  gains the matching step.
- `DATABASE_CONSOLIDATION.md` checks the served catalogue through that log line
  instead of grepping `config/annexes-services.json`, which now also lists entries
  that are switched off.

### Added (Live Data - MQTT telemetry)

- **The `live-data` profile**: `live-data` (API, `ghcr.io/optimce/live-data:main-prod`),
  `live-data-worker` (MQTT ingest) and `live-data-scheduler` (rollups, ownership,
  partitions, retention; same `:main-worker` image), plus the Mosquitto 2.1.2 broker and
  three one-shots (`mosquitto-certs`, `mosquitto-init`, `mosquitto-roles`).
  - **Its own profile, started last and non-fatally** by `docker-stack.sh`: a missing
    certificate, an unset variable or an unpullable image is reported and leaves the
    rest of the platform running. Every command that names it also enables `backend`;
    nothing outside it depends on it, so krakend does not wait for live-data.
  - **The broker publishes 8883 (TLS) only.** TLS terminates in Mosquitto; plaintext
    1883 stays on the new `mqtt` network (broker, roles job, API, ingest worker). The
    TLS listener is an `include_dir` file written by `mosquitto-certs` only when the
    certificate exists, so a missing certificate never stops the broker.
  - **A separate certificate lineage** for `LIVE_DATA_BROKER_PUBLIC_HOST`
    (`mqtt.optimce.be`, decision D-3): `certbot-mqtt` (profile `certs`), RSA,
    `--preferred-chain "ISRG Root X1"` (D-4a) — X1 is trusted until **2030-06-04**, the
    fleet's end-of-life date. The hostname is written into every device and is
    permanent.
  - Only the API holds the broker admin's credentials. The worker and scheduler pass
    the shared production boot check with explicit placeholders: the worker parses
    untrusted device payloads and must not hold the credential that mints and revokes
    devices.
- **`live_data_local` + `live_data_svc`**: provisioned by `postgres-init` (roles,
  database, CONNECT, the CRM grant matrix — SELECT plus `audit_log` INSERT, like
  simulation-key) whether or not the profile runs; `isolation.sh` and
  `positive-writes.sh` prove it (108 and 15 checks on a fresh instance). An empty
  `LIVE_DATA_DB_PASSWORD` does not fail provisioning: Postgres clears the password and
  the role cannot log in. Baseline `schemas/live_data_local.sql` embodies
  `schema_version` 4; the migrator does not manage this database yet.
- **The public enrolment leg**: `location = /api/live-public/enroll` in both nginx
  templates — exact match, the five gateway-trust headers blanked, `limit_req` per IP
  (6r/m, burst 5; a literal, so no variable can render `rate=;`), body capped at 4 KB —
  and a port-80 `server_name mqtt.*` block that serves only the ACME challenge.
- **KrakenD**: `live` and `live-public` (`auth: false`) builder entries over the two
  specs `live-data-doc-gen` downloads. The gateway grows from 191 to 210 endpoints; no
  existing endpoint changes.
- **`docker-stack.sh mqtt-cert`** (first issuance) and **`renew-certs`** (every lineage,
  nginx reload, broker refresh with a restart only if the certificate changed, expiry
  dates printed — run it from cron). Mirrored in `docker-stack.bat`.
- **Backups**: `live_data_local` in `db-backup`, and `mosquitto-backup` copies the
  broker's `dynamic-security.json` — every device's credential, in no database.
- `max_connections` arithmetic on `postgres` updated: 270 of 300.
- `docs/runbooks/live-data.md`.

### Fixed

- **`minio-init` moved from `minio/mc` to `pgsty/mc`**, pinned by digest. `minio/mc`
  on Docker Hub (and `quay.io/minio/mc`) no longer serves anonymous pulls
  ("repository does not exist"), so every `docker compose pull` of the backend
  profile failed — after `docker-stack.sh restart` had already stopped the stack.
  A host that still held an old copy hid it. Same `mc` commands, same Pigsty
  source as the `pgsty/minio` server image; the development stack switched on
  2026-04-22.
- **KrakenD pinned to 2.13.11, by digest.** `krakend:latest` became 3.0.0 on
  2026-09-30, and 3.x refuses the configuration swagger2krakend generates
  (`unsupported version: 3 (want: 4)`): the next `docker compose pull` would have left
  the gateway unable to start and every `/api` route down. 2.13.11 accepts and serves
  this repo's generated config (checked 2026-10-07). `.github/renovate.json` holds
  KrakenD below 3.0 until a swagger2krakend release emits version 4, and Mosquitto
  below 3.0.
- **A consumption import answered 500 although it had succeeded.** KrakenD gave
  every endpoint 3000 ms, and `POST /sharing_operations/consumptions` routinely
  needs more: a one-month, five-meter RESA file took ~3 s, a corrected one ~10 s.
  The gateway answered `500 context deadline exceeded` while crm-backend went on
  to commit, so the manager uploaded again, and an upload overlapping the
  still-running one could store every reading twice. Billing refuses a period
  with duplicated readings. `krakend-builder.yaml` now sets
  `global.stream_timeout: 50s`. The generator applies it only to the 14
  multipart-upload and file-download endpoints:
  - uploads: consumption import, documents, community logo, allocation and
    simulation key files, administrative-document versions;
  - downloads: documents, key files, consumption and audit-log exports, invoice
    PDFs.

  Every other endpoint keeps 3000 ms, and 50 s stays under nginx's default 60 s
  `proxy_read_timeout` on `/api/`.
  - **It needs a `swagger2krakend` image built from d4a8f0a (2026-07-26) or
    later.** The published `ghcr.io/optimce/swagger2krakend:main` is that
    revision, but a host still holding an older pull ignores the key without a
    word. Pull before the `init` profile runs (the default for `docker-stack.sh
    start`, not with `--no-pull`). Then check `krakend_config/krakend.json`, not
    the yaml: it must contain `"timeout": "50s"` 14 times.
  - KrakenD reads the file only at startup, so recreate or restart `krakend`
    after `krakend-config` has regenerated it. `docker-stack.sh restart` does
    both.
  - The other half of the fix ships with the crm-backend image, not with this
    repo: the import itself (~1.3 s instead of ~3 s) and the per-community lock
    that stops an overlapping re-upload from duplicating rows.
- **`docker-stack.bat` reported success for every command, even a failed one.** Each
  branch ended with `exit /b %errorlevel%` inside its `if ( … )` block, and cmd expands
  `%errorlevel%` when it PARSES the block — before the `call` runs — so `verify`
  printed "Verification FAILED" and exited 0, and so did a failed `migrate`, `start`,
  `stop` and `restart`. A wrapper or CI step chaining them saw only successes. They
  now return `!errorlevel!`; the shell script was never affected.
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
    `migration` profile — starting either service before then is a silent
    failure, not a loud one.
  - New `.env` variables: two role passwords plus an email-delivery block
    (`EMAIL_TRANSPORT`, the `SMTP_*` set, the `BREVO_*` set,
    `DISPATCH_POLL_INTERVAL_SECONDS`).
  - The 11 administrative-document template families are vendored under
    `docker-compose/document-templates/` and seeded into MinIO by `minio-init`.
    Its Walloon reference data is **not** loaded — it is applied once as a
    migration rather than on every start. Until then the service runs with an
    empty deadline-rule and template catalogue.
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

### Added (Keycloak)

- Realm internationalization in `keycloak/realm/prod-config.template.json`:
  `internationalizationEnabled`, `supportedLocales` (`fr`, `nl`, `de`, `en`) and
  `defaultLocale`. The `optimce` keycloakify theme ships translations for exactly
  those four, but without these realm settings the language selector never renders
  and none of it is reachable.
  - **The realm import does not apply to an existing realm.** `--import-realm`
    imports only when the realm is absent, so on a running deployment these — and
    `loginTheme` before them — must be set by hand once in the admin console.

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
  Applying this to a running deployment is a scheduled maintenance window, not an
  in-place upgrade.
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
