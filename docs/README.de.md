<p align="center">
  <img src="logo.svg" alt="OptimCE-Logo" width="160">
</p>

# OptimCE — Produktivbereitstellung

[![Website](https://img.shields.io/badge/Website-optimce.be-2e7d32.svg)](https://www.optimce.be/de/)
[![Lizenz](https://img.shields.io/badge/Lizenz-Apache%202.0-blue.svg)](../LICENSE)
[![en](https://img.shields.io/badge/lang-en-lightgrey.svg)](../README.md)
[![fr](https://img.shields.io/badge/lang-fr-lightgrey.svg)](README.fr.md)
[![de](https://img.shields.io/badge/lang-de-43a047.svg)](README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-lightgrey.svg)](README.nl.md)

> Diese Übersetzung wird manuell gepflegt. Bei Abweichungen ist die
> [englische Fassung](../README.md) maßgeblich.

OptimCE ist eine Open-Source-Plattform für die Verwaltung von
Erneuerbare-Energie-Gemeinschaften, entwickelt für den belgischen Kontext des
Energieteilens. Sie vereint ein Mitglieder-CRM, Aufteilungsschlüssel und
Simulationen für das Energieteilen, die Rechnungsstellung, die
Dokumentenerzeugung und ein Gemeinschafts-Schwarzes-Brett hinter einer einzigen
authentifizierten Webanwendung. Mehr über das Projekt erfahren Sie unter
[www.optimce.be](https://www.optimce.be/de/).

Dieses Repository ist die **Referenz-Produktivbereitstellung**: ein
Docker-Compose-Stack, der die veröffentlichten OptimCE-Images
(`ghcr.io/optimce/*`) zusammen mit dem API-Gateway, dem Identitätsanbieter, dem
Reverse Proxy, den Datenbanken und den Sicherungsaufträgen ausführt. Hier wird
nichts gebaut. Für die Entwicklungsumgebung, in der die Dienste als
Git-Submodule eingebunden und aus dem Quellcode gebaut werden, siehe
[OptimCE/monorepo](https://github.com/OptimCE/monorepo).

## Schnellstart

```bash
./docker-stack.sh start
```

Unter Windows verwenden Sie `docker-stack.bat` mit denselben Befehlen.

Prüfen Sie vor dem ersten Start `docker-compose/.env` und ersetzen Sie jeden
Platzhalterwert — siehe [Konfiguration](#konfiguration).

## Dateiformate

| Format | Datei | Zweck |
|--------|-------|-------|
| **YAML** | `docker-compose/docker-compose.yml` | Container-Orchestrierung |
| **JSON** | `docker-compose/keycloak/realm/prod-config.template.json` | Keycloak-Realm-Konfiguration |
| **JSON** | `docker-compose/crm-frontend-config/config.template.json` | Laufzeitkonfiguration des Frontends |
| **YAML** | `docker-compose/krakend_config/krakend-builder.yaml` | Vorlagenbasierte KrakenD-Endpunktkonfiguration |
| **Bash** | `docker-stack.sh` | Bereitstellungsautomatisierung |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-http.template.conf` | Reverse-Proxy-Routing (HTTP) |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-https.template.conf` | Reverse-Proxy-Routing (HTTPS) |

Die `.template.`-Dateien sind die versionierten Quellen. Das `init`-Profil
erzeugt daraus die endgültigen Dateien (`prod-config.json`, `config.json`,
`conf.d/default.conf`) — deshalb stehen diese Ausgaben in der `.gitignore`.

## Dienste

| Dienst | Zweck | Zugriff |
|--------|-------|---------|
| crm-frontend | Angular-Oberfläche | http://localhost |
| crm-backend | Node.js-API | http://localhost/api |
| postgres | PostgreSQL — alle fünf Anwendungsdatenbanken | intern |
| postgres-init | Einmalige Bereitstellung von Rollen, Datenbanken und Rechten | intern |
| allocation-key-generation | API zur Erzeugung von Aufteilungsschlüsseln + Worker | http://localhost/api/generation |
| simulation-key | API zur Simulation von Aufteilungsschlüsseln + Worker | http://localhost/api/simulation |
| news-board | API des Schwarzen Bretts — Beiträge und Umfragen | http://localhost/api/news |
| billing | Rechnungs-API + Worker | http://localhost/api/billing |
| administrative-document | API für regulatorische Vorgänge und Formulare + Worker | http://localhost/api/administrative-document |
| document-generation | NATS-Worker, der Rechnungs- und Abrechnungs-PDFs erzeugt | intern |
| notification-dispatch | Worker für den Versand eingereihter E-Mails — der einzige Absender | intern |
| keycloak | IAM/OIDC | http://localhost/keycloak |
| keycloak-db | PostgreSQL — nur Keycloak, separate Instanz | intern |
| krakend | API-Gateway | http://localhost/api |
| minio | S3-kompatibler Speicher | intern |
| nats | JetStream-Message-Broker | intern |
| reverse-proxy | NGINX-Reverse-Proxy | http://localhost |

## Befehle

```bash
./docker-stack.sh start           # Kompletter Stack
./docker-stack.sh start --no-pull # Ohne Image-Download
./docker-stack.sh stop            # Alles stoppen (löst eine automatische Sicherung aus)
./docker-stack.sh restart         # Neu starten (löst eine automatische Sicherung aus)
./docker-stack.sh verify          # Datenbankisolation und CRM-Rechte nachweisen
./docker-stack.sh help            # Hilfe anzeigen
```

`start` und `restart` akzeptieren außerdem zwei Wartezeit-Optionen, die jeder
Schicht Zeit geben, sich zu stabilisieren, bevor die nächste startet:

```bash
./docker-stack.sh start --wait-init 30     # Wartesekunden nach dem init-Profil (Standard: 10)
./docker-stack.sh start --wait-backend 30  # Wartesekunden nach dem backend-Profil (Standard: 10)
```

## Profile

Docker-Compose-Profile steuern, welche Dienste starten:

| Profil | Dienste | Zweck |
|--------|---------|-------|
| `init` | swagger-doc-gen, generation-doc-gen, simulation-doc-gen, news-board-doc-gen, billing-doc-gen, administrative-document-doc-gen, krakend-config, keycloak-config, nginx-config, crm-frontend-config, keycloak-group-id-mapper, keycloak-optimce-theme | Einmalige Konfigurationsgeneratoren und Provider-Downloads |
| `backend` | postgres, postgres-init, keycloak-db, keycloak, keycloak-healthcheck, crm-backend, allocation-key-generation (+ Worker), simulation-key (+ Worker), news-board, billing (+ Worker), administrative-document (+ Worker), document-generation, notification-dispatch, nats, minio, minio-init, krakend | Kerninfrastruktur |
| `frontend` | reverse-proxy, certbot, crm-frontend | Web-Auslieferungsschicht |
| `migration` | optimce-migrator | Einmalige CRM-Schemamigrationen |
| `backup` | db-backup, keycloak-db-backup | Datenbank-Sicherungsdienste |

Der Standardstart führt `init`, dann `backend`, dann `frontend` aus.

Das `migration`-Profil muss mit `backend` kombiniert werden, da der Migrator von
`postgres` abhängt:

```bash
docker compose --profile backend --profile migration run --rm optimce-migrator --dry-run
docker compose --profile backend --profile migration run --rm optimce-migrator
```

## Datenbanken

Eine einzige PostgreSQL-Instanz (`postgres`) beherbergt alle sechs
Anwendungsdatenbanken, jede im Besitz ihrer eigenen Login-Rolle, wobei sich
`PUBLIC` mit keiner von ihnen verbinden kann. `keycloak-db` bleibt bewusst eine
separate Instanz.

| Datenbank | Besitzerrolle | Besitzender Dienst |
|-----------|---------------|--------------------|
| `crm_db` | `crm_svc` | crm-backend, optimce-migrator |
| `allocation_key_local` | `allocation_key_svc` | allocation-key-generation (+ Worker) |
| `simulation_key_local` | `simulation_key_svc` | simulation-key (+ Worker) |
| `news_board_local` | `news_board_svc` | news-board |
| `billing_local` | `billing_svc` | billing (+ Worker) |
| `administrative_document_local` | `administrative_document_svc` | administrative-document (+ Worker) |
| `keycloak` | `postgres` | keycloak — **separate Instanz** |

Eine siebte Rolle, `notification_dispatch_svc`, besitzt keine Datenbank: die
Warteschlange von notification-dispatch liegt im CRM-Schema, damit das Einreihen
eines Produzenten in dessen eigener Transaktion mitläuft.

Jeder Zusatzdienst greift außerdem überwiegend lesend auf `crm_db` zu; was er dort
schreiben darf, erzwingt die Datenbank und nicht eine Konvention. `postgres-init`
führt bei jedem Start `docker-compose/postgres/provision/provision.sh` aus, um
Rollen, Passwörter, Datenbanken, Eigentum und Rechte zu konvergieren — siehe
[`docker-compose/postgres/README.md`](../docker-compose/postgres/README.md).

```bash
./docker-stack.sh verify   # Isolation und CRM-Rechtematrix nachweisen
```

Die Migration einer bestehenden Bereitstellung mit getrennten Instanzen in dieses
Layout beschreibt
[DATABASE_CONSOLIDATION.md](../DATABASE_CONSOLIDATION.md).

## Automatische Sicherungen

Sicherungen laufen automatisch vor `stop` oder `restart`. `db-backup` sichert alle
Anwendungsdatenbanken sowie die clusterweiten Rollendefinitionen in einem Auftrag;
`keycloak-db-backup` deckt die separate Keycloak-Instanz ab:

- Rollen und Passwörter → `backups/globals_YYYYMMDD_HHMMSS.sql`
- CRM → `backups/crm_db_YYYYMMDD_HHMMSS.sql`
- Aufteilungsschlüssel → `backups/allocation_key_YYYYMMDD_HHMMSS.sql`
- Simulation → `backups/simulation_key_YYYYMMDD_HHMMSS.sql`
- Schwarzes Brett → `backups/news_board_YYYYMMDD_HHMMSS.sql`
- Rechnungsstellung → `backups/billing_YYYYMMDD_HHMMSS.sql`
- Verwaltungsdokumente → `backups/administrative_document_YYYYMMDD_HHMMSS.sql`
- Keycloak → `backups/keycloak_YYYYMMDD_HHMMSS.sql`

Der Globals-Dump ist nicht optional: Rollendefinitionen und ihre Passwort-Hashes
liegen in der Instanz, nicht in einer einzelnen Datenbank. Ohne ihn lässt sich aus
einer Reihe von Datenbank-Dumps kein funktionierender Cluster wiederherstellen.

Ein fehlgeschlagener Dump wird gemeldet, bricht die übrigen aber nicht ab und blockiert das Herunterfahren nicht.
Eine Aufbewahrungsbereinigung ist derzeit nicht implementiert; alte Sicherungsdateien müssen manuell entfernt werden.

Manuelle Sicherung:
```bash
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm keycloak-db-backup
```

Die Sicherungen werden in `docker-compose/backups/` abgelegt.

## Konfiguration

Bearbeiten Sie `docker-compose/.env`, um URLs, Authentifizierungseinstellungen und Datenbank-Zugangsdaten zu konfigurieren.

⚠️ **Wichtig**: Die in `docker-compose/.env` ausgelieferten Werte sind
Platzhalter (`changeme…`, `admin`, `minioadmin`, `http://localhost`). Ersetzen
Sie sie alle — Datenbankpasswörter, `AUTH_CLIENT_SECRET`,
`KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD`, die MinIO-Root-Zugangsdaten, `DOMAIN` —
bevor Sie den Stack in einem Netzwerk verfügbar machen.

> Hinweis: `docker-compose/krakend_config/krakend-builder.yaml` ist die Quellvorlage für die KrakenD-Endpunktdefinitionen. Ändern Sie diese Datei, wenn Sie Upstream-Hosts von Diensten oder realmbezogene Variablen ändern oder neue API-Endpunkte hinzufügen.

### Mitgelieferte Konfiguration

Drei Verzeichnisse enthalten Konfiguration, die aus den Anwendungs-Repositories kopiert wurde. Sie ist **nicht** in die
veröffentlichten Images eingebacken und muss daher synchron gehalten werden, wenn sich der zugehörige Dienst ändert:

| Pfad | Quelle | Genutzt von |
|------|--------|-------------|
| `docker-compose/reference/regulators.json` | Monorepo `reference/regulators.json` | `crm-backend`, `billing`, `billing-worker` (schreibgeschützt unter `/app/reference` eingehängt) |
| `docker-compose/schemas/<datenbank>.sql` | `scripts/sql/schema.sql` des jeweiligen Dienstes | `postgres-init`, nur auf eine **leere** Datenbank angewandt |
| `docker-compose/document-templates/billing/` | `billing/document-templates/billing/` | von `minio-init` in den Bucket `optimce-templates` eingespielt |

Die Dateien unter `docker-compose/schemas/` sind Ausgangsstände für die
Notfallwiederherstellung, keine Migrationen: `postgres-init` wendet eine davon nur
an, wenn ihre Datenbank überhaupt keine Tabelle enthält. `crm_db.sql` ist
insbesondere der v0-Ausgangsstand — das reale CRM-Schema wird vom
`migration`-Profil fortgeschrieben, und ein erneutes Anwenden würde Daten
zerstören (die Datei beginnt mit `DROP SCHEMA public CASCADE`), was die
Absicherung genau verhindert.

`crm-backend` und `billing` **starten beide nicht**, wenn `regulators.json` fehlt oder nicht lesbar ist —
es gibt keinen Ausweichpfad. Einen zusätzlichen Regulator als `active` zu markieren, erfordert außerdem ein passendes
Abrechnungsregime im billing-Image, sonst gerät `billing` bei seiner Konsistenzprüfung beim Start in eine Absturzschleife.

### Einen neuen Zusatzdienst hinzufügen

1. Fügen Sie dem `init`-Profil einen einmaligen `<service>-doc-gen`-Container hinzu, der auf die veröffentlichte
   `https://optimce.github.io/<repo>/swagger.yml` des Dienstes zeigt, und tragen Sie ihn in `krakend-config.depends_on` ein.
2. Fügen Sie den Dienstblock in `krakend_config/krakend-builder.yaml` mit seinem **Container**-Port hinzu —
   beachten Sie, dass dies nicht immer 8000 ist (`allocation-key-generation` lauscht in seinem Produktions-Image
   auf 8002).
3. Fügen Sie den Laufzeitdienst hinzu. Seine Datenbank ist **kein** neuer
   Container: ergänzen Sie eine Rolle in `postgres/provision/00-roles.sql`, eine
   Zeile samt `GRANT CONNECT` in `10-databases.sql`, einen Eintrag im
   `DATABASES`-Register von `provision.sh` und einen
   `./schemas/<datenbank>.sql`-Mount an `postgres-init`. Koppeln Sie den Dienst an
   `postgres-init: condition: service_completed_successfully`, geben Sie ihm das
   Netzwerk `database` und fixieren Sie seine vier Pool-Variablen.
4. Erweitern Sie `postgres/verify/isolation.sh` und
   `postgres/verify/positive-writes.sh`, sonst ist die neue Rechtegrenze
   ungeschützt. Nehmen Sie die Datenbank auch in die Schleife von `db-backup` auf.

## Mitwirken

Beiträge sind willkommen! Bitte lesen Sie die
[Beitragsrichtlinien](../CONTRIBUTING.md) und unseren
[Verhaltenskodex](../CODE_OF_CONDUCT.md) (auf Englisch), bevor Sie ein Issue
oder einen Pull Request eröffnen.

## Sicherheit

Um eine Sicherheitslücke zu melden, folgen Sie bitte der
[Sicherheitsrichtlinie](../SECURITY.md) — eröffnen Sie kein öffentliches Issue.

## Lizenz

Dieses Projekt steht unter der [Apache-Lizenz 2.0](../LICENSE).
