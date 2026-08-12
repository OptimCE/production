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
| reverse-proxy | NGINX reverse proxy | http://localhost |

## Commands

```bash
./docker-stack.sh start           # Full stack
./docker-stack.sh start --no-pull # Skip image pulls
./docker-stack.sh stop            # Stop all (triggers automatic backup)
./docker-stack.sh restart         # Restart (triggers automatic backup)
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
| `backend` | postgres, postgres-init, keycloak-db, keycloak, keycloak-healthcheck, crm-backend, allocation-key-generation (+ worker), simulation-key (+ worker), news-board, billing (+ worker), administrative-document (+ worker), document-generation, notification-dispatch, nats, minio, minio-init, krakend | Core infrastructure |
| `frontend` | reverse-proxy, certbot, crm-frontend | Web serving layer |
| `migration` | optimce-migrator | One-shot CRM schema migrations |
| `backup` | db-backup, keycloak-db-backup | Database backup services |

Default startup runs `init`, then `backend`, then `frontend`.

The `migration` profile must be combined with `backend`, since the migrator depends on
`postgres` and `postgres-init`:

```bash
docker compose --profile backend --profile migration run --rm optimce-migrator --dry-run
docker compose --profile backend --profile migration run --rm optimce-migrator
```

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
| `docker-compose/schemas/<database>.sql` | each service's `scripts/sql/schema.sql` | `postgres-init`, applied only to an **empty** database |
| `docker-compose/document-templates/billing/` | `billing/document-templates/billing/` | seeded into the `optimce-templates` bucket by `minio-init` |

The files under `docker-compose/schemas/` are disaster-recovery baselines, not
migrations: `postgres-init` applies one only when its database has no table at
all. `crm_db.sql` in particular is the v0 baseline — the live CRM schema is
carried forward by the `migration` profile, and re-applying the baseline would
destroy data (it opens with `DROP SCHEMA public CASCADE`), which is exactly what
the guard prevents.

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
