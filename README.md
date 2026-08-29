<p align="center">
  <img src="docs/logo.svg" alt="OptimCE logo" width="160">
</p>

# OptimCE — Production Deployment

[![Website](https://img.shields.io/badge/Website-optimce.be-2e7d32.svg)](https://www.optimce.be/en/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![en](https://img.shields.io/badge/lang-en-43a047.svg)](README.md)
[![fr](https://img.shields.io/badge/lang-fr-lightgrey.svg)](docs/README.fr.md)
[![de](https://img.shields.io/badge/lang-de-lightgrey.svg)](docs/README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-lightgrey.svg)](docs/README.nl.md)

OptimCE is an open-source platform for managing renewable energy communities,
built for the Belgian energy-sharing context. It brings together a member CRM,
energy-sharing allocation keys and simulations, invoicing, document generation,
and a community news board, behind a single authenticated web application.
To learn more about the project, visit
[www.optimce.be](https://www.optimce.be/en/).

This repository is the **reference production deployment**: a Docker Compose
stack that runs the published OptimCE images (`ghcr.io/optimce/*`) together with
the API gateway, the identity provider, the reverse proxy, the databases, and
the backup jobs. Nothing is built here. For the development environment, where
the services are included as git submodules and built from source, see
[OptimCE/monorepo](https://github.com/OptimCE/monorepo).

## Quick Start

```bash
./docker-stack.sh start
```

On Windows, use `docker-stack.bat` with the same commands.

Before the first start, review `docker-compose/.env` and replace every
placeholder value — see [Configuration](#configuration).

## Available Syntaxes

| Format | File | Purpose |
|--------|------|---------|
| **YAML** | `docker-compose/docker-compose.yml` | Container orchestration |
| **JSON** | `docker-compose/keycloak/realm/prod-config.template.json` | Keycloak realm configuration |
| **JSON** | `docker-compose/crm-frontend-config/config.template.json` | Frontend runtime config |
| **YAML** | `docker-compose/krakend_config/krakend-builder.yaml` | KrakenD template-driven endpoint configuration |
| **Bash** | `docker-stack.sh` | Deployment automation |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-http.template.conf` | Reverse proxy routing (HTTP) |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-https.template.conf` | Reverse proxy routing (HTTPS) |

The `.template.` files are the committed sources. The `init` profile renders
them into their final form (`prod-config.json`, `config.json`,
`conf.d/default.conf`), which is why those outputs are listed in `.gitignore`.

## Services

| Service | Purpose | Access |
|---------|---------|--------|
| crm-frontend | Angular UI | http://localhost |
| crm-backend | Node.js API | http://localhost/api |
| postgres | PostgreSQL — all five application databases | internal |
| postgres-init | One-shot provisioning of roles, databases and grants | internal |
| allocation-key-generation | Allocation-key generation API + worker | http://localhost/api/generation |
| simulation-key | Allocation-key simulation API + worker | http://localhost/api/simulation |
| news-board | News board API — posts & polls | http://localhost/api/news |
| billing | Invoicing API + worker | http://localhost/api/billing |
| administrative-document | Regulatory dossiers & forms API + worker | http://localhost/api/administrative-document |
| document-generation | NATS worker rendering invoice/statement PDFs | internal |
| notification-dispatch | Worker delivering queued email — the only sender | internal |
| keycloak | IAM/OIDC | http://localhost/keycloak |
| keycloak-db | PostgreSQL — Keycloak only, separate instance | internal |
| krakend | API Gateway | http://localhost/api |
| minio | S3-compatible storage | internal |
| nats | JetStream message broker | internal |
| redis | Realtime (SSE) ticket store and pub/sub bus | internal |
| reverse-proxy | NGINX reverse proxy | http://localhost |

## Commands

```bash
./docker-stack.sh start           # Full stack
./docker-stack.sh start --no-pull # Skip image pulls
./docker-stack.sh stop            # Stop all (triggers automatic backup)
./docker-stack.sh restart         # Restart (triggers automatic backup)
./docker-stack.sh migrate         # Apply pending migrations, then re-converge grants
./docker-stack.sh migrate --dry-run  # Report what is pending, change nothing
./docker-stack.sh verify          # Prove database isolation and the CRM grants
./docker-stack.sh help            # Show usage
```

`start` and `restart` also accept two timing options, used to give each layer
time to settle before the next one starts:

```bash
./docker-stack.sh start --wait-init 30     # Seconds to wait after the init profile (default: 10)
./docker-stack.sh start --wait-backend 30  # Seconds to wait after the backend profile (default: 10)
```

## Profiles

Docker Compose profiles control which services start:

| Profile | Services | Purpose |
|---------|----------|---------|
| `init` | swagger-doc-gen, generation-doc-gen, simulation-doc-gen, news-board-doc-gen, billing-doc-gen, administrative-document-doc-gen, krakend-config, keycloak-config, nginx-config, crm-frontend-config, keycloak-group-id-mapper, keycloak-optimce-theme | One-shot config generators and provider downloads |
| `backend` | postgres, postgres-init, keycloak-db, keycloak, keycloak-healthcheck, crm-backend, allocation-key-generation (+ worker), simulation-key (+ worker), news-board, billing (+ worker), administrative-document (+ worker), document-generation, notification-dispatch, nats, redis, minio, minio-init, krakend | Core infrastructure |
| `frontend` | reverse-proxy, certbot, crm-frontend | Web serving layer |
| `migration` | optimce-migrator | One-shot schema migrations, all six databases |
| `backup` | db-backup, keycloak-db-backup | Database backup services |

Default startup runs `init`, then `backend`, then `frontend`.

**Use `./docker-stack.sh migrate`**, not the raw compose commands. It does the same
thing and then re-runs `postgres-init`, which is not optional: objects the migrator
creates arrive with no grant for the annexe roles until the matrix reconverges, and a
missing CRM grant is silent at runtime — the API returns 200 and the row never appears.
It re-converges even when the migrator fails, because each migration commits in its own
transaction, so a part-way failure leaves earlier ones applied and ungranted.

The `migration` profile must be combined with `backend`, since the migrator depends on
`postgres` and `postgres-init`. Underneath, the command runs:

```bash
docker compose --profile backend --profile migration pull optimce-migrator
docker compose --profile backend --profile migration run --rm optimce-migrator --dry-run
docker compose --profile backend --profile migration run --rm optimce-migrator
docker compose --profile backend run --rm postgres-init
```

The migrator manages **six** databases and needs one URL for each — they are supplied by
the `optimce-migrator` block in `docker-compose.yml`, built from the role passwords
already in `.env`. It resolves the whole set up front and exits 1 on the first one it
cannot find, before opening a connection. **Pull this repo before pulling the image**: a
migrator release that adds a database ships its URL in the same commit.

Before migrating, stop `allocation-key-generation`, `allocation-key-generation-worker`,
`simulation-key` and `simulation-key-worker`. The annexe migrations take
`ACCESS EXCLUSIVE` on `generation` and `simulation`; with `lock_timeout` at its default
of 0, a worker holding an open transaction makes the migrator wait forever, and every
later query then queues behind the migrator.

## Databases

One PostgreSQL instance (`postgres`) holds all six application databases, each
owned by its own login role, with `PUBLIC` unable to connect to any of them.
`keycloak-db` is deliberately a separate instance.

| database | owner role | owning service |
|----------|-----------|----------------|
| `crm_db` | `crm_svc` | crm-backend, optimce-migrator |
| `allocation_key_local` | `allocation_key_svc` | allocation-key-generation (+ worker) |
| `simulation_key_local` | `simulation_key_svc` | simulation-key (+ worker) |
| `news_board_local` | `news_board_svc` | news-board |
| `billing_local` | `billing_svc` | billing (+ worker) |
| `administrative_document_local` | `administrative_document_svc` | administrative-document (+ worker) |
| `keycloak` | `postgres` | keycloak — **separate instance** |

A seventh role, `notification_dispatch_svc`, owns no database: notification-dispatch's
queue lives in the CRM schema so a producer's enqueue rides on its own transaction.

Each annexe service also reaches `crm_db` as a read-mostly consumer; what it may
write there is enforced by the database, not by convention. `postgres-init` runs
`docker-compose/postgres/provision/provision.sh` on every start to converge
roles, passwords, databases, ownership and grants — see
[`docker-compose/postgres/README.md`](docker-compose/postgres/README.md).

```bash
./docker-stack.sh verify   # prove the isolation and the CRM grant matrix
```

Migrating an existing split-instance deployment into this layout is documented in
[DATABASE_CONSOLIDATION.md](DATABASE_CONSOLIDATION.md).

## Realtime (SSE) and maps

The notification bell and the module dashboards can be pushed to rather than polled.
The design has two legs, and only the second one is unusual:

1. **Mint** — `POST /api/notifications/realtime/ticket`, behind KrakenD like every other
   call, returns a single-use ticket with a short TTL.
2. **Stream** — `GET ${WEB_REALTIME_PATH}` (default `/realtime/stream`), which
   **bypasses the API gateway**. It has to: `EventSource` cannot send an `Authorization`
   header, so KrakenD's validator can never be satisfied, and KrakenD buffers and
   JSON-decodes with a 3000 ms global timeout. nginx proxies this one exact path
   straight to `crm-backend`, clearing the five gateway-trust headers so they cannot be
   forged on the way in. The ticket in `?t=` is the only credential.

`redis` holds the tickets and carries the pub/sub fan-out. It is deliberately not the
NATS broker: job dispatch must not lose messages, realtime is allowed to.

**`REALTIME_ENABLED` ships `false`.** With it false the ticket endpoint 503s,
`crm-backend` opens no Redis connection, every annexe `emit()` is a no-op, and the SPA
polls exactly as it did before. That is the rollout and the rollback both — flipping the
variable and running `docker compose --profile backend up -d` is the whole operation in
either direction.

> A realtime failure is **indistinguishable from a quiet system**: the pollers keep the
> UI correct, so "nobody complained" proves nothing. The signal is the startup log line —
> each of the nine producers logs `Realtime disabled — … publishes nothing` or
> `Realtime publisher ready — …`. An image built before the feature logs **neither**,
> while its environment variables look perfectly correct.

Two consequences worth knowing before the first deploy:

- **The reverse proxy now refuses to start unless `crm-backend` resolves.** nginx
  resolves `upstream` names at config load. Start `backend` before `frontend` —
  `docker-stack.sh` already does.
- `WEB_REALTIME_PATH` renders **both** the nginx location and the frontend's
  `config.json`, so they cannot drift. Leaving it empty renders `location =  {`, an
  nginx syntax error that takes the proxy down.

The map views (meters as pins, communities as commune zones) need coordinates on
`address`, which arrive as a CRM migration — not from this repo. `GEOCODING_MODE` ships
`LOCAL`, which never leaves the process; `REMOTE` additionally allows two free Belgian
public geocoders and is reachable only from the admin-only `POST /geocoding/backfill`.

Full procedures: [`docs/runbooks/realtime-sse.md`](docs/runbooks/realtime-sse.md) and
[`docs/runbooks/map-views.md`](docs/runbooks/map-views.md).

## Automatic Backups

Backups run automatically before `stop` or `restart`. `db-backup` dumps every
application database plus the cluster-wide role definitions in one job;
`keycloak-db-backup` covers the separate Keycloak instance:

- Roles and passwords → `backups/globals_YYYYMMDD_HHMMSS.sql`
- CRM → `backups/crm_db_YYYYMMDD_HHMMSS.sql`
- Allocation-key → `backups/allocation_key_YYYYMMDD_HHMMSS.sql`
- Simulation-key → `backups/simulation_key_YYYYMMDD_HHMMSS.sql`
- News-board → `backups/news_board_YYYYMMDD_HHMMSS.sql`
- Billing → `backups/billing_YYYYMMDD_HHMMSS.sql`
- Administrative-document → `backups/administrative_document_YYYYMMDD_HHMMSS.sql`
- Keycloak → `backups/keycloak_YYYYMMDD_HHMMSS.sql`

The globals dump is not optional: role definitions and their password hashes live
in the instance, not in any single database, so a set of per-database dumps
without it cannot rebuild a working cluster.

A failing dump is reported but does not abort the others or block the shutdown.
Retention cleanup is not currently implemented; old backup files must be removed manually.

Manual backup:
```bash
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm keycloak-db-backup
```

Backups are stored in `docker-compose/backups/`.

## Configuration

Edit `docker-compose/.env` to configure URLs, auth settings, and database credentials.

⚠️ **Important**: the values shipped in `docker-compose/.env` are placeholders
(`changeme…`, `admin`, `minioadmin`, `http://localhost`). Replace every one of
them — database passwords, `AUTH_CLIENT_SECRET`,
`KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD`, the MinIO root credentials, `DOMAIN` — before
exposing the stack to a network.

> Note: `docker-compose/krakend_config/krakend-builder.yaml` is the source template for KrakenD endpoint definitions. Update this file when changing upstream service hosts, realm-related variables, or adding new API endpoints.

### Vendored configuration

Three directories hold config copied from the application repos. They are **not** baked into the
published images, so they must be kept in sync when the corresponding service changes:

| Path | Source | Consumed by |
|------|--------|-------------|
| `docker-compose/reference/regulators.json` | monorepo `reference/regulators.json` | `crm-backend`, `billing`, `billing-worker` (mounted read-only at `/app/reference`) |
| `docker-compose/schemas/crm_db.sql` | monorepo `crm-backend/database_script/init.sql` | `postgres-init`, applied only to an **empty** database |
| `docker-compose/schemas/<annexe>.sql` | each annexe's `scripts/sql/schema.sql` | `postgres-init`, applied only to an **empty** database |
| `docker-compose/document-templates/billing/` | `billing/document-templates/billing/` | seeded into the `optimce-templates` bucket by `minio-init` |
| `docker-compose/document-templates/administrative-document/` | `administrative-document/document-templates/administrative-document/` | seeded into the same bucket by `minio-init` |

The files under `docker-compose/schemas/` are disaster-recovery baselines, not
migrations: `postgres-init` applies one only when its database has no table at
all. `crm_db.sql` in particular is the v0 baseline — the live CRM schema is
carried forward by the `migration` profile, and re-applying the baseline would
destroy data (it opens with `DROP SCHEMA public CASCADE`), which is exactly what
the guard prevents.

> **`crm_db.sql` tracks `crm-backend/database_script/init.sql`, never
> `crm-backend/tests/sql/init.sql`.** The development stack mounts the latter, and it is
> the same schema plus 72 fixture `INSERT`s — fake addresses, users, communities and
> meters — and eight `ALTER TABLE … RESTART WITH 10` sequence resets. Copying the wrong
> one seeds fake tenants into a freshly built production CRM.

An annexe's `schema.sql` self-inserts a `schema_version` row for **every version it
already embodies**, so a fresh install lands at that annexe's current version and the
migrator correctly reports nothing pending. That is the property that makes a
rebuild-from-empty and a migrated database converge — and it only holds while these
files are actually in sync with the monorepo.

`crm-backend` and `billing` both **fail to start** if `regulators.json` is missing or unreadable —
there is no fallback path. Marking an additional regulator `active` also requires a matching billing
regime inside the billing image, or `billing` will crash-loop on its startup parity check.

### Adding a new annex service

1. Add a `<service>-doc-gen` one-shot to the `init` profile pointing at the service's published
   `https://optimce.github.io/<repo>/swagger.yml`, and list it in `krakend-config.depends_on`.
2. Add the service block to `krakend_config/krakend-builder.yaml` with its **container** port —
   note this is not always 8000 (`allocation-key-generation` listens on 8002 in its production
   image).
3. Add the runtime service. Its database is **not** a new container: add a role to
   `postgres/provision/00-roles.sql`, a row plus a `GRANT CONNECT` to
   `10-databases.sql`, a line to the `DATABASES` registry in `provision.sh`, and a
   `./schemas/<database>.sql` mount on `postgres-init`. Gate the service on
   `postgres-init: condition: service_completed_successfully`, give it the
   `database` network, and pin its four pool variables.
4. Extend `postgres/verify/isolation.sh` and `postgres/verify/positive-writes.sh`,
   or the new privilege boundary is undefended. `db-backup` picks the database up
   from its own loop — add it there too.

## Contributing

Contributions are welcome! Please read the
[contributing guidelines](CONTRIBUTING.md) and our
[Code of Conduct](CODE_OF_CONDUCT.md) before opening an issue or pull request.

## Security

To report a security vulnerability, please follow the
[security policy](SECURITY.md) — do not open a public issue.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
