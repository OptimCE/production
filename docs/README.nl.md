<p align="center">
  <img src="logo.svg" alt="OptimCE-logo" width="160">
</p>

# OptimCE — Productie-uitrol

[![Website](https://img.shields.io/badge/Website-optimce.be-2e7d32.svg)](https://www.optimce.be/nl/)
[![Licentie](https://img.shields.io/badge/Licentie-Apache%202.0-blue.svg)](../LICENSE)
[![en](https://img.shields.io/badge/lang-en-lightgrey.svg)](../README.md)
[![fr](https://img.shields.io/badge/lang-fr-lightgrey.svg)](README.fr.md)
[![de](https://img.shields.io/badge/lang-de-lightgrey.svg)](README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-43a047.svg)](README.nl.md)

> Deze vertaling wordt handmatig bijgehouden. Bij verschillen is de
> [Engelse versie](../README.md) doorslaggevend.

OptimCE is een opensourceplatform voor het beheer van
hernieuwbare-energiegemeenschappen, ontwikkeld voor de Belgische context van
energiedelen. Het brengt een ledenbeheer-CRM, verdeelsleutels en simulaties voor
energiedelen, facturatie, documentgeneratie en een gemeenschapsnieuwsbord samen
achter één geauthenticeerde webtoepassing. Meer over het project vindt u op
[www.optimce.be](https://www.optimce.be/nl/).

Deze repository is de **referentie-uitrol voor productie**: een
Docker Compose-stack die de gepubliceerde OptimCE-images (`ghcr.io/optimce/*`)
uitvoert, samen met de API-gateway, de identiteitsprovider, de reverse proxy, de
databanken en de back-uptaken. Hier wordt niets gebouwd. Voor de
ontwikkelomgeving, waar de diensten als git-submodules zijn opgenomen en vanuit
de broncode worden gebouwd, zie
[OptimCE/monorepo](https://github.com/OptimCE/monorepo).

## Snel starten

```bash
./docker-stack.sh start
```

Op Windows gebruikt u `docker-stack.bat` met dezelfde commando's.

Neem vóór de eerste start `docker-compose/.env` door en vervang elke
tijdelijke waarde — zie [Configuratie](#configuratie).

## Bestandsformaten

| Formaat | Bestand | Doel |
|---------|---------|------|
| **YAML** | `docker-compose/docker-compose.yml` | Containerorkestratie |
| **JSON** | `docker-compose/keycloak/realm/prod-config.template.json` | Keycloak-realmconfiguratie |
| **JSON** | `docker-compose/crm-frontend-config/config.template.json` | Runtimeconfiguratie van de frontend |
| **YAML** | `docker-compose/krakend_config/krakend-builder.yaml` | Sjabloongestuurde KrakenD-endpointconfiguratie |
| **Bash** | `docker-stack.sh` | Automatisering van de uitrol |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-http.template.conf` | Reverse-proxyrouting (HTTP) |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-https.template.conf` | Reverse-proxyrouting (HTTPS) |

De `.template.`-bestanden zijn de versiebeheerde bronnen. Het `init`-profiel
zet ze om naar hun definitieve vorm (`prod-config.json`, `config.json`,
`conf.d/default.conf`); daarom staan die uitvoerbestanden in `.gitignore`.

## Diensten

| Dienst | Doel | Toegang |
|--------|------|---------|
| crm-frontend | Angular-interface | http://localhost |
| crm-backend | Node.js-API | http://localhost/api |
| postgres | PostgreSQL — alle vijf applicatiedatabanken | intern |
| postgres-init | Eenmalige provisioning van rollen, databanken en rechten | intern |
| allocation-key-generation | API voor het genereren van verdeelsleutels + worker | http://localhost/api/generation |
| simulation-key | API voor het simuleren van verdeelsleutels + worker | http://localhost/api/simulation |
| news-board | API van het nieuwsbord — berichten en polls | http://localhost/api/news |
| billing | Facturatie-API + worker | http://localhost/api/billing |
| administrative-document | API voor reglementaire dossiers en formulieren + worker | http://localhost/api/administrative-document |
| document-generation | NATS-worker die factuur- en afrekening-PDF's genereert | intern |
| notification-dispatch | Worker die de e-mailwachtrij verzendt — de enige verzender | intern |
| keycloak | IAM/OIDC | http://localhost/keycloak |
| keycloak-db | PostgreSQL — enkel Keycloak, aparte instantie | intern |
| krakend | API-gateway | http://localhost/api |
| minio | S3-compatibele opslag | intern |
| nats | JetStream-messagebroker | intern |
| reverse-proxy | NGINX-reverse-proxy | http://localhost |

## Commando's

```bash
./docker-stack.sh start           # Volledige stack
./docker-stack.sh start --no-pull # Images niet ophalen
./docker-stack.sh stop            # Alles stoppen (start automatisch een back-up)
./docker-stack.sh restart         # Herstarten (start automatisch een back-up)
./docker-stack.sh verify          # Databankisolatie en CRM-rechten aantonen
./docker-stack.sh help            # Hulp tonen
```

`start` en `restart` aanvaarden daarnaast twee wachttijdopties, die elke laag de
tijd geven om te stabiliseren voordat de volgende start:

```bash
./docker-stack.sh start --wait-init 30     # Wachtseconden na het init-profiel (standaard: 10)
./docker-stack.sh start --wait-backend 30  # Wachtseconden na het backend-profiel (standaard: 10)
```

## Profielen

Docker Compose-profielen bepalen welke diensten starten:

| Profiel | Diensten | Doel |
|---------|----------|------|
| `init` | swagger-doc-gen, generation-doc-gen, simulation-doc-gen, news-board-doc-gen, billing-doc-gen, administrative-document-doc-gen, krakend-config, keycloak-config, nginx-config, crm-frontend-config, keycloak-group-id-mapper, keycloak-optimce-theme | Eenmalige configuratiegeneratoren en downloads van providers |
| `backend` | postgres, postgres-init, keycloak-db, keycloak, keycloak-healthcheck, crm-backend, allocation-key-generation (+ worker), simulation-key (+ worker), news-board, billing (+ worker), administrative-document (+ worker), document-generation, notification-dispatch, nats, minio, minio-init, krakend | Kerninfrastructuur |
| `frontend` | reverse-proxy, certbot, crm-frontend | Weblaag |
| `migration` | optimce-migrator | Eenmalige CRM-schemamigraties |
| `backup` | db-backup, keycloak-db-backup | Back-updiensten voor de databanken |

Bij een standaardstart draaien achtereenvolgens `init`, `backend` en `frontend`.

Het `migration`-profiel moet worden gecombineerd met `backend`, omdat de migrator afhangt van
`postgres`:

```bash
docker compose --profile backend --profile migration run --rm optimce-migrator --dry-run
docker compose --profile backend --profile migration run --rm optimce-migrator
```

## Databanken

Eén PostgreSQL-instantie (`postgres`) huisvest alle zes applicatiedatabanken,
elk in eigendom van een eigen loginrol, waarbij `PUBLIC` met geen enkele ervan
verbinding kan maken. `keycloak-db` blijft bewust een aparte instantie.

| Databank | Eigenaarsrol | Eigenaardienst |
|----------|--------------|----------------|
| `crm_db` | `crm_svc` | crm-backend, optimce-migrator |
| `allocation_key_local` | `allocation_key_svc` | allocation-key-generation (+ worker) |
| `simulation_key_local` | `simulation_key_svc` | simulation-key (+ worker) |
| `news_board_local` | `news_board_svc` | news-board |
| `billing_local` | `billing_svc` | billing (+ worker) |
| `administrative_document_local` | `administrative_document_svc` | administrative-document (+ worker) |
| `keycloak` | `postgres` | keycloak — **aparte instantie** |

Een zevende rol, `notification_dispatch_svc`, bezit geen databank: de wachtrij van
notification-dispatch zit in het CRM-schema zodat het inschrijven door een
producent binnen diens eigen transactie meeloopt.

Elke annexdienst benadert daarnaast `crm_db` als hoofdzakelijk lezende gebruiker;
wat hij daar mag schrijven wordt door de databank afgedwongen en niet door
afspraak. `postgres-init` voert bij elke start
`docker-compose/postgres/provision/provision.sh` uit om rollen, wachtwoorden,
databanken, eigendom en rechten te laten convergeren — zie
[`docker-compose/postgres/README.md`](../docker-compose/postgres/README.md).

```bash
./docker-stack.sh verify   # de isolatie en de CRM-rechtenmatrix aantonen
```

Het migreren van een bestaande opstelling met aparte instanties naar deze indeling
staat beschreven in
[DATABASE_CONSOLIDATION.md](../DATABASE_CONSOLIDATION.md).

## Automatische back-ups

Back-ups draaien automatisch vóór `stop` of `restart`. `db-backup` dumpt alle
applicatiedatabanken plus de clusterbrede roldefinities in één taak;
`keycloak-db-backup` dekt de aparte Keycloak-instantie:

- Rollen en wachtwoorden → `backups/globals_YYYYMMDD_HHMMSS.sql`
- CRM → `backups/crm_db_YYYYMMDD_HHMMSS.sql`
- Verdeelsleutels → `backups/allocation_key_YYYYMMDD_HHMMSS.sql`
- Simulatie → `backups/simulation_key_YYYYMMDD_HHMMSS.sql`
- Nieuwsbord → `backups/news_board_YYYYMMDD_HHMMSS.sql`
- Facturatie → `backups/billing_YYYYMMDD_HHMMSS.sql`
- Administratieve documenten → `backups/administrative_document_YYYYMMDD_HHMMSS.sql`
- Keycloak → `backups/keycloak_YYYYMMDD_HHMMSS.sql`

De globals-dump is niet optioneel: roldefinities en hun wachtwoordhashes zitten in
de instantie, niet in een afzonderlijke databank. Zonder die dump kan een reeks
databankdumps geen werkend cluster herstellen.

Een mislukte dump wordt gemeld, maar breekt de andere niet af en blokkeert het afsluiten niet.
Er is momenteel geen opruiming van oude back-ups; oude back-upbestanden moeten handmatig worden verwijderd.

Handmatige back-up:
```bash
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm keycloak-db-backup
```

De back-ups worden bewaard in `docker-compose/backups/`.

## Configuratie

Bewerk `docker-compose/.env` om URL's, authenticatie-instellingen en databankgegevens te configureren.

⚠️ **Belangrijk**: de waarden in `docker-compose/.env` zijn tijdelijke waarden
(`changeme…`, `admin`, `minioadmin`, `http://localhost`). Vervang ze allemaal —
databankwachtwoorden, `AUTH_CLIENT_SECRET`,
`KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD`, de MinIO-rootgegevens, `DOMAIN` — voordat u
de stack op een netwerk beschikbaar maakt.

> Opmerking: `docker-compose/krakend_config/krakend-builder.yaml` is het bronsjabloon voor de KrakenD-endpointdefinities. Pas dit bestand aan wanneer u upstreamhosts van diensten of realmgebonden variabelen wijzigt, of nieuwe API-endpoints toevoegt.

### Meegeleverde configuratie

Drie mappen bevatten configuratie die uit de applicatierepository's is gekopieerd. Ze zit **niet** in de
gepubliceerde images en moet dus worden bijgewerkt wanneer de bijbehorende dienst verandert:

| Pad | Bron | Gebruikt door |
|-----|------|---------------|
| `docker-compose/reference/regulators.json` | monorepo `reference/regulators.json` | `crm-backend`, `billing`, `billing-worker` (alleen-lezen gekoppeld op `/app/reference`) |
| `docker-compose/schemas/<databank>.sql` | `scripts/sql/schema.sql` van elke dienst | `postgres-init`, enkel toegepast op een **lege** databank |
| `docker-compose/document-templates/billing/` | `billing/document-templates/billing/` | door `minio-init` in de bucket `optimce-templates` geplaatst |

De bestanden onder `docker-compose/schemas/` zijn uitgangspunten voor
noodherstel, geen migraties: `postgres-init` past er pas één toe wanneer de
bijbehorende databank helemaal geen tabel bevat. `crm_db.sql` is met name het
v0-uitgangspunt — het echte CRM-schema wordt door het `migration`-profiel
bijgewerkt, en opnieuw toepassen zou gegevens vernietigen (het bestand begint met
`DROP SCHEMA public CASCADE`), precies wat de beveiliging voorkomt.

Zowel `crm-backend` als `billing` **starten niet** wanneer `regulators.json` ontbreekt of onleesbaar is —
er is geen terugvaloptie. Een bijkomende regulator als `active` markeren vereist bovendien een overeenkomstig
facturatieregime in de billing-image, anders blijft `billing` crashen op zijn controle bij het opstarten.

### Een nieuwe annexdienst toevoegen

1. Voeg aan het `init`-profiel een eenmalige `<service>-doc-gen` toe die verwijst naar de gepubliceerde
   `https://optimce.github.io/<repo>/swagger.yml` van de dienst, en vermeld die in `krakend-config.depends_on`.
2. Voeg het dienstblok toe aan `krakend_config/krakend-builder.yaml` met zijn **container**poort —
   let op: dat is niet altijd 8000 (`allocation-key-generation` luistert in zijn productie-image
   op 8002).
3. Voeg de runtimedienst toe. Zijn databank is **geen** nieuwe container: voeg een
   rol toe in `postgres/provision/00-roles.sql`, een regel plus een
   `GRANT CONNECT` in `10-databases.sql`, een regel in het `DATABASES`-register van
   `provision.sh`, en een `./schemas/<databank>.sql`-mount op `postgres-init`.
   Laat de dienst afhangen van
   `postgres-init: condition: service_completed_successfully`, geef hem het
   netwerk `database` en zet zijn vier poolvariabelen vast.
4. Breid `postgres/verify/isolation.sh` en `postgres/verify/positive-writes.sh`
   uit, anders is de nieuwe rechtengrens onbewaakt. Voeg de databank ook toe aan de
   lus van `db-backup`.

## Bijdragen

Bijdragen zijn welkom! Lees de
[bijdragerichtlijnen](../CONTRIBUTING.md) en onze
[gedragscode](../CODE_OF_CONDUCT.md) (in het Engels) voordat u een issue of pull
request opent.

## Beveiliging

Volg de [beveiligingsrichtlijn](../SECURITY.md) om een kwetsbaarheid te melden —
open geen publieke issue.

## Licentie

Dit project valt onder de [Apache-licentie 2.0](../LICENSE).
