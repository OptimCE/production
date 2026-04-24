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
| keycloak | IAM/OIDC | http://localhost/keycloak |
| krakend | API Gateway | http://localhost/api |
| minio | S3-compatible storage | internal |
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
| `backend` | crm-database, keycloak, crm-backend, minio, krakend | Core infrastructure |
| `frontend` | reverse-proxy, crm-frontend | Web serving layer |
| `init` | keycloak-config, swagger-doc-gen, krakend-config, crm-frontend-config | One-shot config generators |
| `backup` | crm-database-backup, keycloak-db-backup | Database backup services |

Default startup uses `backend` + `frontend` profiles.

## Automatic Backups

Backups run automatically before `stop` or `restart`:
- CRM database → `backups/crm_db_YYYYMMDD_HHMMSS.sql`
- Keycloak database → `backups/keycloak_YYYYMMDD_HHMMSS.sql`
- Retention: files older than 7 days are auto-deleted

Manual backup:
```bash
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm crm-database-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm keycloak-db-backup
```

Backups are stored in `docker-compose/backups/`.

## Configuration

Edit `docker-compose/.env` to configure URLs, auth settings, and database credentials.

> Note: `docker-compose/krakend_config/krakend-builder.yaml` is the source template for KrakenD endpoint definitions. Update this file when changing upstream service hosts, realm-related variables, or adding new API endpoints.
