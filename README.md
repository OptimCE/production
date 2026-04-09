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
|---------|--------|--------|
| crm-frontend | React UI | http://localhost |
| crm-backend | Node.js API | http://localhost/api |
| crm-database | PostgreSQL | internal |
| keycloak | IAM/OIDC | http://localhost/keycloak |
| krakend | API Gateway | http://localhost/api |
| jaeger | Distributed tracing | http://localhost:16686 |

## Commands

```bash
./docker-stack.sh start          # Full stack
./docker-stack.sh start --no-pull # Skip image pulls
./docker-stack.sh stop            # Stop all
./docker-stack.sh restart         # Restart
```

## Configuration

Edit `docker-compose/.env` to configure URLs, auth settings, and database credentials.

> Note: `docker-compose/krakend_config/krakend-builder.yaml` is the source template for KrakenD service definitions. Update this file when changing upstream service hosts, realm-related variables, or endpoint generation inputs.
