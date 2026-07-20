# OptimCE CRM Stack

Docker-based microservices infrastructure for a Customer Relationship Management application.

## Quick Start

```bash
./docker-stack.sh start
```

## Available Syntaxes

| Format | File | Purpose |
|--------|------|---------|
| **YAML** | `docker-compose/docker-compose.yml` | Container orchestration |
| **JSON** | `docker-compose/keycloak/realm/prod-config.json` | Keycloak realm configuration |
| **JSON** | `docker-compose/crm-frontend-config/config.json` | Frontend runtime config |
| **YAML** | `docker-compose/krakend_config/krakend-builder.yaml` | KrakenD template-driven endpoint configuration |
| **Bash** | `docker-stack.sh` | Deployment automation |
| **NGINX Conf** | `docker-compose/nginx/conf.d/default.conf` | Reverse proxy routing |

## Services

| Service | Purpose | Access |
|---------|---------|--------|
| crm-frontend | React UI | http://localhost |
| crm-backend | Node.js API | http://localhost/api |
| crm-database | PostgreSQL | internal |
| allocation-key-generation | Allocation-key generation API + worker (+ DB) | http://localhost/api/generation |
| simulation-key | Allocation-key simulation API + worker (+ DB) | http://localhost/api/simulation |
| news-board | News board API — posts & polls (+ DB) | http://localhost/api/news |
| billing | Invoicing API + worker (+ DB) | http://localhost/api/billing |
| document-generation | NATS worker rendering invoice/statement PDFs | internal |
| keycloak | IAM/OIDC | http://localhost/keycloak |
| krakend | API Gateway | http://localhost/api |
| minio | S3-compatible storage | internal |
| nats | JetStream message broker | internal |
| reverse-proxy | NGINX reverse proxy | http://localhost |

## Commands

```bash
./docker-stack.sh start          # Full stack
./docker-stack.sh start --no-pull # Skip image pulls
./docker-stack.sh stop           # Stop all (triggers automatic backup)
./docker-stack.sh restart        # Restart (triggers automatic backup)
```

## Profiles

Docker Compose profiles control which services start:

| Profile | Services | Purpose |
|---------|----------|---------|
| `backend` | crm-database, keycloak, crm-backend, allocation-key-generation, simulation-key, news-board, billing, document-generation, nats, minio, krakend | Core infrastructure |
| `frontend` | reverse-proxy, crm-frontend | Web serving layer |
| `init` | keycloak-config, swagger-doc-gen, generation-doc-gen, simulation-doc-gen, news-board-doc-gen, billing-doc-gen, krakend-config, crm-frontend-config | One-shot config generators |
| `migration` | optimce-migrator | One-shot CRM schema migrations |
| `backup` | crm-database-backup, keycloak-db-backup, allocation-key-db-backup, simulation-key-db-backup, news-board-db-backup, billing-db-backup | Database backup services |

Default startup uses `backend` + `frontend` profiles.

The `migration` profile must be combined with `backend`, since the migrator depends on
`crm-database`:

```bash
docker compose --profile backend --profile migration run --rm optimce-migrator --dry-run
docker compose --profile backend --profile migration run --rm optimce-migrator
```

## Automatic Backups

Backups run automatically before `stop` or `restart`, one dump per database:
- CRM → `backups/crm_db_YYYYMMDD_HHMMSS.sql`
- Keycloak → `backups/keycloak_YYYYMMDD_HHMMSS.sql`
- Allocation-key → `backups/allocation_key_YYYYMMDD_HHMMSS.sql`
- Simulation-key → `backups/simulation_key_YYYYMMDD_HHMMSS.sql`
- News-board → `backups/news_board_YYYYMMDD_HHMMSS.sql`
- Billing → `backups/billing_YYYYMMDD_HHMMSS.sql`

A failing dump is reported but does not abort the others or block the shutdown.
Retention cleanup is not currently implemented; old backup files must be removed manually.

Manual backup:
```bash
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm crm-database-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm keycloak-db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm allocation-key-db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm simulation-key-db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm news-board-db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm billing-db-backup
```

Backups are stored in `docker-compose/backups/`.

## Configuration

Edit `docker-compose/.env` to configure URLs, auth settings, and database credentials.

> Note: `docker-compose/krakend_config/krakend-builder.yaml` is the source template for KrakenD endpoint definitions. Update this file when changing upstream service hosts, realm-related variables, or adding new API endpoints.

### Vendored configuration

Three directories hold config copied from the application repos. They are **not** baked into the
published images, so they must be kept in sync when the corresponding service changes:

| Path | Source | Consumed by |
|------|--------|-------------|
| `docker-compose/reference/regulators.json` | monorepo `reference/regulators.json` | `crm-backend`, `billing`, `billing-worker` (mounted read-only at `/app/reference`) |
| `docker-compose/billing-db/docker-entrypoint-initdb.d/init.sql` | `billing/scripts/sql/schema.sql` | `billing-db` first boot only |
| `docker-compose/document-templates/billing/` | `billing/document-templates/billing/` | seeded into the `optimce-templates` bucket by `minio-init` |

`crm-backend` and `billing` both **fail to start** if `regulators.json` is missing or unreadable —
there is no fallback path. Marking an additional regulator `active` also requires a matching billing
regime inside the billing image, or `billing` will crash-loop on its startup parity check.

### Adding a new annex service

1. Add a `<service>-doc-gen` one-shot to the `init` profile pointing at the service's published
   `https://optimce.github.io/<repo>/swagger.yml`, and list it in `krakend-config.depends_on`.
2. Add the service block to `krakend_config/krakend-builder.yaml` with its **container** port —
   note this is not always 8000 (`allocation-key-generation` listens on 8002 in its production
   image).
3. Add the runtime service, its database, a `*-db-backup` job, the volume, and the network.
