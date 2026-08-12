# The unified Postgres instance

One PostgreSQL instance (compose service `postgres`) holds six logical databases,
each owned by its own login role. `keycloak-db` remains a separate instance — see
[Why Keycloak is not here](#why-keycloak-is-not-here).

| database | owner role | owning service | password variable |
|---|---|---|---|
| `crm_db` | `crm_svc` | crm-backend, optimce-migrator | `CRM_DB_PASSWORD` |
| `allocation_key_local` | `allocation_key_svc` | allocation-key-generation (+ worker) | `ALLOCATION_KEY_DB_PASSWORD` |
| `simulation_key_local` | `simulation_key_svc` | simulation-key (+ worker) | `SIMULATION_KEY_DB_PASSWORD` |
| `news_board_local` | `news_board_svc` | news-board | `NEWS_BOARD_DB_PASSWORD` |
| `billing_local` | `billing_svc` | billing (+ worker) | `BILLING_DB_PASSWORD` |
| `administrative_document_local` | `administrative_document_svc` | administrative-document (+ worker) | `ADMINISTRATIVE_DOCUMENT_DB_PASSWORD` |

Plus a **seventh role that owns no database**: `notification_dispatch_svc`
(`NOTIFICATION_DISPATCH_DB_PASSWORD`). notification-dispatch's queue is
`outbound_message`, which lives in the CRM schema so that a producer's enqueue
rides on that producer's own transaction. So the role exists purely to hold two
narrow write grants on `crm_db`.

Each `*_DB_PASSWORD` in `docker-compose/.env` is **one login role's** password,
not an instance superuser's. `POSTGRES_SUPERUSER_PASSWORD` is separate and is
used only by `postgres-init` and the backup job.

## The CRM port

Every annexe service opens **two** connections: its own database, and `crm_db`
as a **read-mostly** consumer. What "read-mostly" means is enforced by
`provision/30-crm-grants.sql`, not by convention:

| role | on `crm_db` |
|---|---|
| `crm_svc` | owner — everything |
| `allocation_key_svc` | SELECT all; INSERT `audit_log`, `allocation_key`, `iteration`, `consumer` |
| `simulation_key_svc` | SELECT all; INSERT `audit_log` |
| `news_board_svc` | SELECT all; INSERT `audit_log`, `notification`, `outbound_message` |
| `billing_svc` | SELECT all; INSERT `audit_log`, `notification`, `outbound_message` |
| `administrative_document_svc` | SELECT all; INSERT `audit_log`, `notification`, `outbound_message` |
| `notification_dispatch_svc` | SELECT all; **UPDATE** `outbound_message`; INSERT `email_suppression` |

`notification_dispatch_svc` is the only role in the whole matrix holding an
`UPDATE`, and it holds nothing else — it never enqueues a message and never writes
an audit row. The `UPDATE` is load-bearing twice over: `SELECT … FOR UPDATE SKIP
LOCKED` requires the privilege in its own right, so the same grant covers both the
claim loop and the CLAIMED/SENT/FAILED/SUPPRESSED transitions.

Nobody but `crm_svc` holds DELETE or CREATE anywhere in `crm_db`.

### The write grants are guarded, on purpose

Not one of the tables in the write matrix ships in this repo's control.
`schemas/crm_db.sql` is the v0 baseline for a *fresh* database; the live one is
whatever `ghcr.io/optimce/migrator:main` has made it. `audit_log` arrived at
schema_version 5; the notification-delivery tables have not reached this
deployment line yet at all.

So every write grant is wrapped in a `to_regclass` existence check.
A hard `GRANT` would abort provisioning and leave the whole stack refusing to
start whenever an unrelated image had not yet shipped a table — and it would
deadlock disaster recovery, since the tables cannot exist before the stack that
creates them can start. **Provisioning converges; `verify/positive-writes.sh`
asserts.** A grant that is expected but absent produces a loud `WARNING`; one that
is simply not on this release line produces a `NOTICE` and lights up by itself
later.

## One provisioning path

`provision/provision.sh` runs as the `postgres-init` sidecar on **every** `up`
and converges the instance. `/docker-entrypoint-initdb.d` is deliberately left
unmounted: those scripts run only on an empty data directory and only against
`POSTGRES_DB`, so they can neither converge a rotated password nor reach a second
database. Two mechanisms would also be two things that can diverge.

| step | file | re-runs? |
|---|---|---|
| 1. roles + passwords | `00-roles.sql` | yes — always re-asserts, so rotation works |
| 2. databases + `REVOKE CONNECT … FROM PUBLIC` | `10-databases.sql` | yes — `\gexec` yields no rows once they exist |
| 3. schema ownership | `20-schema-owner.sql` | yes, no-op |
| 4. schemas, applied **as the owner** | `21-set-role.sql` + `/schemas/<db>.sql` | **no — guarded on an empty `public`** |
| 5. CRM grants | `30-crm-grants.sql` | yes — converges after a migrator release adds a table |

**There is no seed step here, deliberately.** The monorepo's copy of
`provision.sh` applies `/seeds/<db>/*.sql` on every run, which is right for
development and wrong for production: what a database contains should be a
function of its migration history, not of how many times it has been restarted.
Reference data ships as a migration like every other change — see
[DATABASE_CONSOLIDATION.md](../../DATABASE_CONSOLIDATION.md) §9.8. That missing
block is the one intentional behavioural difference between the two copies of the
script.

`set -eu` plus `ON_ERROR_STOP=1` on every `psql` means a failure exits the
container non-zero, and every service gated on
`postgres-init: condition: service_completed_successfully` refuses to start.
There is no state in which the stack comes up with half its grants — which
matters because a missing CRM grant produces **no** application error.

### The schemas are a baseline, not a migration mechanism

`docker-compose/schemas/*.sql` are applied only when the target database has no
table in `public`. In a running production that is never: the databases are
populated. They exist so an empty volume can be rebuilt from scratch.

`crm_db.sql` in particular is the **v0 baseline** and opens with
`DROP SCHEMA IF EXISTS public CASCADE`. `crm_db`'s real schema is carried forward
by `ghcr.io/optimce/migrator:main` (profile `migration`). The guard is what keeps
the baseline from destroying data.

Keep them in step with the monorepo — they are vendored copies, and a stale one
only shows up when someone rebuilds from an empty volume:

| this file | monorepo source |
|---|---|
| `crm_db.sql` | `crm-backend/database_script/init.sql` (the pure-DDL sibling, **not** `tests/sql/init.sql`) |
| `<service>_local.sql` | that service's `scripts/sql/schema.sql` |

## Verify, don't assume

```bash
./docker-stack.sh verify
```

- `verify/isolation.sh` — every role must **fail** to reach every database it
  does not own, and every annexe must fail UPDATE / DELETE / INSERT / CREATE on
  `crm_db`.
- `verify/positive-writes.sh` — every *granted* write must actually land. Wrapped
  in `BEGIN … ROLLBACK`, so it is safe against live data.

Run both **twice**: after a first init, and after a `restart`. Only the restart
case exercises convergence.

`positive-writes.sh` is not optional and "we saw no 500s" is not a substitute for
it. The annexes wrap their `audit_log` INSERT in a SAVEPOINT under a blanket
`except Exception`, so a missing grant returns 200 to the caller and silently
drops the audit row.

## Rotating a password

Edit the variable in `docker-compose/.env`, then `./docker-stack.sh restart` —
**not** `start`. `provision.sh` re-asserts every password on every run, but a
container that is already running keeps the environment it was created with.

## The CRM schema is owned elsewhere

`optimce-migrator` is an external image (`ghcr.io/optimce/migrator:main`) and the
compose file runs it as **`crm_svc`**, not as `postgres`. That is deliberate:
`ALTER DEFAULT PRIVILEGES` in `30-crm-grants.sql` applies only to objects created
by `crm_svc`, so a table the migrator creates as `postgres` would arrive with no
SELECT grant for any annexe — and the failure would be a silent
`no privileges were granted for ...` **warning**, not an error.

If a migrator release ever needs superuser, run it as `postgres`, then repair
with `provision/91-reown-crm.sql` followed by another `postgres-init` run.

**Re-run `postgres-init` after any migrator run.** New tables arrive ungranted
until it converges them.

## Adding a seventh database

Five mechanical edits:

1. A role in `provision/00-roles.sql` (and its `-v` binding in `provision.sh`).
2. A row plus a `GRANT CONNECT` in `provision/10-databases.sql`.
3. A line in the `DATABASES` registry in `provision/provision.sh`.
4. A `./schemas/<database>.sql:/schemas/<database>.sql:ro` mount on
   `postgres-init` in `docker-compose.yml`, plus the password variable and the
   service's own DSN.
5. The database in the `db-backup` loop.

Then extend `verify/isolation.sh` and `verify/positive-writes.sh`, or the new
boundary is undefended.

A service that needs **only** CRM access and owns no database — as
notification-dispatch does — skips steps 2 (the `CREATE DATABASE` row), 3 and 5,
and appears in `10-databases.sql` only in the `crm_db` `GRANT CONNECT` list.

If the service ships **reference data**, it does not go here. Seeds are not a
mechanism in this deployment: reference data is applied once, as a migration, and
recorded in that database's `schema_version`. See
[DATABASE_CONSOLIDATION.md](../../DATABASE_CONSOLIDATION.md) §9.8 for how, and why
the monorepo does it differently.

## Why Keycloak is not here

Keycloak manages its own schema with an internal Liquibase at startup, and it is
the one service whose failure locks everyone out of everything. Leaving it on
`keycloak-db` keeps the identity provider out of the blast radius of this
instance, and gives these seven roles no route to it at all — a stronger
guarantee than a `REVOKE`.

## The accepted trade-off

One instance restart now takes every service down. Against that: four fewer
postmasters — and a sixth database that cost none — one backup target, one
connection budget, and a privilege boundary the database enforces instead of one
the code promises. There is no replication or failover here; adding it is its own
project.
