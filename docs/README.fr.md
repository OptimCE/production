<p align="center">
  <img src="logo.svg" alt="Logo OptimCE" width="160">
</p>

# OptimCE — Déploiement de production

[![Site web](https://img.shields.io/badge/Site%20web-optimce.be-2e7d32.svg)](https://www.optimce.be)
[![Licence](https://img.shields.io/badge/Licence-Apache%202.0-blue.svg)](../LICENSE)
[![en](https://img.shields.io/badge/lang-en-lightgrey.svg)](../README.md)
[![fr](https://img.shields.io/badge/lang-fr-43a047.svg)](README.fr.md)
[![de](https://img.shields.io/badge/lang-de-lightgrey.svg)](README.de.md)
[![nl](https://img.shields.io/badge/lang-nl-lightgrey.svg)](README.nl.md)

> Cette traduction est maintenue manuellement. En cas de divergence, la
> [version anglaise](../README.md) fait foi.

OptimCE est une plateforme open source de gestion des communautés d'énergie
renouvelable, conçue pour le contexte belge du partage d'énergie. Elle réunit
un CRM des membres, les clés de répartition et les simulations de partage
d'énergie, la facturation, la génération de documents et un tableau
d'actualités communautaire, derrière une application web unique et
authentifiée. Pour en savoir plus sur le projet, consultez
[www.optimce.be](https://www.optimce.be).

Ce dépôt est le **déploiement de production de référence** : une pile Docker
Compose qui exécute les images OptimCE publiées (`ghcr.io/optimce/*`) avec la
passerelle d'API, le fournisseur d'identité, le reverse proxy, les bases de
données et les tâches de sauvegarde. Rien n'est construit ici. Pour
l'environnement de développement, où les services sont inclus comme
sous-modules git et compilés depuis les sources, voir
[OptimCE/monorepo](https://github.com/OptimCE/monorepo).

## Démarrage rapide

```bash
./docker-stack.sh start
```

Sous Windows, utilisez `docker-stack.bat` avec les mêmes commandes.

Avant le premier démarrage, relisez `docker-compose/.env` et remplacez chaque
valeur d'exemple — voir [Configuration](#configuration).

## Formats de fichiers

| Format | Fichier | Rôle |
|--------|---------|------|
| **YAML** | `docker-compose/docker-compose.yml` | Orchestration des conteneurs |
| **JSON** | `docker-compose/keycloak/realm/prod-config.template.json` | Configuration du realm Keycloak |
| **JSON** | `docker-compose/crm-frontend-config/config.template.json` | Configuration d'exécution du frontend |
| **YAML** | `docker-compose/krakend_config/krakend-builder.yaml` | Configuration des endpoints KrakenD par gabarit |
| **Bash** | `docker-stack.sh` | Automatisation du déploiement |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-http.template.conf` | Routage du reverse proxy (HTTP) |
| **NGINX Conf** | `docker-compose/nginx/conf-template.d/default-https.template.conf` | Routage du reverse proxy (HTTPS) |

Les fichiers `.template.` sont les sources versionnées. Le profil `init` les
transforme en leur version finale (`prod-config.json`, `config.json`,
`conf.d/default.conf`), c'est pourquoi ces sorties figurent dans `.gitignore`.

## Services

| Service | Rôle | Accès |
|---------|------|-------|
| crm-frontend | Interface Angular | http://localhost |
| crm-backend | API Node.js | http://localhost/api |
| postgres | PostgreSQL — les cinq bases applicatives | interne |
| postgres-init | Provisionnement à usage unique des rôles, bases et droits | interne |
| allocation-key-generation | API de génération de clés de répartition + worker | http://localhost/api/generation |
| simulation-key | API de simulation de clés de répartition + worker | http://localhost/api/simulation |
| news-board | API du tableau d'actualités — publications et sondages | http://localhost/api/news |
| billing | API de facturation + worker | http://localhost/api/billing |
| administrative-document | API des dossiers et formulaires réglementaires + worker | http://localhost/api/administrative-document |
| document-generation | Worker NATS générant les PDF de factures et de décomptes | interne |
| notification-dispatch | Worker d'envoi des e-mails en file — le seul émetteur | interne |
| keycloak | IAM/OIDC | http://localhost/keycloak |
| keycloak-db | PostgreSQL — Keycloak uniquement, instance séparée | interne |
| krakend | Passerelle d'API | http://localhost/api |
| minio | Stockage compatible S3 | interne |
| nats | Courtier de messages JetStream | interne |
| reverse-proxy | Reverse proxy NGINX | http://localhost |

## Commandes

```bash
./docker-stack.sh start           # Pile complète
./docker-stack.sh start --no-pull # Sans télécharger les images
./docker-stack.sh stop            # Tout arrêter (déclenche une sauvegarde automatique)
./docker-stack.sh restart         # Redémarrer (déclenche une sauvegarde automatique)
./docker-stack.sh verify          # Prouver l'isolation des bases et les droits CRM
./docker-stack.sh help            # Afficher l'aide
```

`start` et `restart` acceptent également deux options de temporisation, qui
laissent à chaque couche le temps de se stabiliser avant le démarrage de la
suivante :

```bash
./docker-stack.sh start --wait-init 30     # Secondes d'attente après le profil init (défaut : 10)
./docker-stack.sh start --wait-backend 30  # Secondes d'attente après le profil backend (défaut : 10)
```

## Profils

Les profils Docker Compose déterminent quels services démarrent :

| Profil | Services | Rôle |
|--------|----------|------|
| `init` | swagger-doc-gen, generation-doc-gen, simulation-doc-gen, news-board-doc-gen, billing-doc-gen, administrative-document-doc-gen, krakend-config, keycloak-config, nginx-config, crm-frontend-config, keycloak-group-id-mapper, keycloak-optimce-theme | Générateurs de configuration à usage unique et téléchargement des providers |
| `backend` | postgres, postgres-init, keycloak-db, keycloak, keycloak-healthcheck, crm-backend, allocation-key-generation (+ worker), simulation-key (+ worker), news-board, billing (+ worker), administrative-document (+ worker), document-generation, notification-dispatch, nats, minio, minio-init, krakend | Infrastructure principale |
| `frontend` | reverse-proxy, certbot, crm-frontend | Couche de service web |
| `migration` | optimce-migrator | Migrations de schéma CRM à usage unique |
| `backup` | db-backup, keycloak-db-backup | Services de sauvegarde des bases de données |

Le démarrage par défaut exécute `init`, puis `backend`, puis `frontend`.

Le profil `migration` doit être combiné avec `backend`, car le migrateur dépend de
`postgres` :

```bash
docker compose --profile backend --profile migration run --rm optimce-migrator --dry-run
docker compose --profile backend --profile migration run --rm optimce-migrator
```

## Bases de données

Une seule instance PostgreSQL (`postgres`) héberge les six bases applicatives,
chacune détenue par son propre rôle de connexion, `PUBLIC` ne pouvant se connecter
à aucune d'elles. `keycloak-db` reste délibérément une instance séparée.

| Base | Rôle propriétaire | Service propriétaire |
|------|-------------------|----------------------|
| `crm_db` | `crm_svc` | crm-backend, optimce-migrator |
| `allocation_key_local` | `allocation_key_svc` | allocation-key-generation (+ worker) |
| `simulation_key_local` | `simulation_key_svc` | simulation-key (+ worker) |
| `news_board_local` | `news_board_svc` | news-board |
| `billing_local` | `billing_svc` | billing (+ worker) |
| `administrative_document_local` | `administrative_document_svc` | administrative-document (+ worker) |
| `keycloak` | `postgres` | keycloak — **instance séparée** |

Un septième rôle, `notification_dispatch_svc`, ne possède aucune base : la file
d'attente de notification-dispatch réside dans le schéma CRM afin que la mise en
file d'un producteur s'inscrive dans sa propre transaction.

Chaque service annexe accède aussi à `crm_db` en lecture quasi exclusive ; ce
qu'il peut y écrire est imposé par la base, non par convention. `postgres-init`
exécute `docker-compose/postgres/provision/provision.sh` à chaque démarrage pour
converger rôles, mots de passe, bases, propriété et droits — voir
[`docker-compose/postgres/README.md`](../docker-compose/postgres/README.md).

```bash
./docker-stack.sh verify   # prouver l'isolation et la matrice de droits CRM
```

La migration d'un déploiement existant à instances séparées vers cette
architecture est décrite dans
[DATABASE_CONSOLIDATION.md](../DATABASE_CONSOLIDATION.md).

## Sauvegardes automatiques

Les sauvegardes s'exécutent automatiquement avant `stop` ou `restart`. `db-backup`
sauvegarde toutes les bases applicatives ainsi que les définitions de rôles de
l'instance ; `keycloak-db-backup` couvre l'instance Keycloak séparée :

- Rôles et mots de passe → `backups/globals_YYYYMMDD_HHMMSS.sql`
- CRM → `backups/crm_db_YYYYMMDD_HHMMSS.sql`
- Clés de répartition → `backups/allocation_key_YYYYMMDD_HHMMSS.sql`
- Simulation → `backups/simulation_key_YYYYMMDD_HHMMSS.sql`
- Tableau d'actualités → `backups/news_board_YYYYMMDD_HHMMSS.sql`
- Facturation → `backups/billing_YYYYMMDD_HHMMSS.sql`
- Documents administratifs → `backups/administrative_document_YYYYMMDD_HHMMSS.sql`
- Keycloak → `backups/keycloak_YYYYMMDD_HHMMSS.sql`

Le dump des « globals » n'est pas optionnel : les définitions de rôles et leurs
empreintes de mot de passe résident dans l'instance et non dans une base
particulière ; sans lui, un ensemble de dumps ne permet pas de reconstruire un
cluster fonctionnel.

L'échec d'un dump est signalé mais n'interrompt pas les autres et ne bloque pas l'arrêt.
Aucune purge de rétention n'est implémentée pour l'instant ; les anciennes sauvegardes doivent être supprimées manuellement.

Sauvegarde manuelle :
```bash
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm db-backup
docker compose -f docker-compose/docker-compose.yml --profile backup run --rm keycloak-db-backup
```

Les sauvegardes sont stockées dans `docker-compose/backups/`.

## Configuration

Modifiez `docker-compose/.env` pour configurer les URL, les paramètres d'authentification et les identifiants des bases de données.

⚠️ **Important** : les valeurs livrées dans `docker-compose/.env` sont des
exemples (`changeme…`, `admin`, `minioadmin`, `http://localhost`). Remplacez-les
toutes — mots de passe des bases de données, `AUTH_CLIENT_SECRET`,
`KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD`, identifiants root MinIO, `DOMAIN` — avant
d'exposer la pile sur un réseau.

> Note : `docker-compose/krakend_config/krakend-builder.yaml` est le gabarit source des définitions d'endpoints KrakenD. Modifiez ce fichier lorsque vous changez les hôtes des services amont, les variables liées au realm, ou lorsque vous ajoutez de nouveaux endpoints d'API.

### Configuration vendorisée

Trois répertoires contiennent de la configuration copiée depuis les dépôts applicatifs. Elle n'est **pas** intégrée aux
images publiées : elle doit donc être tenue à jour lorsque le service correspondant change :

| Chemin | Source | Consommé par |
|--------|--------|--------------|
| `docker-compose/reference/regulators.json` | monorepo `reference/regulators.json` | `crm-backend`, `billing`, `billing-worker` (monté en lecture seule sur `/app/reference`) |
| `docker-compose/schemas/<base>.sql` | `scripts/sql/schema.sql` de chaque service | `postgres-init`, appliqué uniquement à une base **vide** |
| `docker-compose/document-templates/billing/` | `billing/document-templates/billing/` | déposé dans le bucket `optimce-templates` par `minio-init` |

Les fichiers de `docker-compose/schemas/` sont des références de reprise après
sinistre, pas des migrations : `postgres-init` n'en applique un que lorsque sa base
ne contient aucune table. `crm_db.sql` est en particulier la référence v0 — le
schéma CRM réel est porté par le profil `migration`, et réappliquer la référence
détruirait les données (elle débute par `DROP SCHEMA public CASCADE`), ce que le
garde-fou empêche précisément.

`crm-backend` et `billing` **refusent tous deux de démarrer** si `regulators.json` est absent ou illisible —
il n'existe aucun mécanisme de repli. Marquer un régulateur supplémentaire comme `active` exige également un régime de
facturation correspondant dans l'image billing, faute de quoi `billing` bouclera en erreur lors de sa vérification de cohérence au démarrage.

### Ajouter un nouveau service annexe

1. Ajoutez un conteneur `<service>-doc-gen` à usage unique dans le profil `init`, pointant vers le
   `https://optimce.github.io/<repo>/swagger.yml` publié du service, et référencez-le dans `krakend-config.depends_on`.
2. Ajoutez le bloc du service dans `krakend_config/krakend-builder.yaml` avec son port **conteneur** —
   notez qu'il ne s'agit pas toujours de 8000 (`allocation-key-generation` écoute sur 8002 dans son image
   de production).
3. Ajoutez le service d'exécution. Sa base de données n'est **pas** un nouveau
   conteneur : ajoutez un rôle dans `postgres/provision/00-roles.sql`, une ligne et
   un `GRANT CONNECT` dans `10-databases.sql`, une entrée au registre `DATABASES`
   de `provision.sh`, et un montage `./schemas/<base>.sql` sur `postgres-init`.
   Conditionnez le service à
   `postgres-init: condition: service_completed_successfully`, donnez-lui le
   réseau `database` et fixez ses quatre variables de pool.
4. Étendez `postgres/verify/isolation.sh` et `postgres/verify/positive-writes.sh`,
   sans quoi la nouvelle frontière de privilèges n'est pas défendue. Ajoutez aussi
   la base à la boucle de `db-backup`.

## Contribuer

Les contributions sont les bienvenues ! Merci de lire le
[guide de contribution](../CONTRIBUTING.md) et notre
[code de conduite](../CODE_OF_CONDUCT.md) (en anglais) avant d'ouvrir une issue
ou une pull request.

## Sécurité

Pour signaler une faille de sécurité, veuillez suivre la
[politique de sécurité](../SECURITY.md) — n'ouvrez pas d'issue publique.

## Licence

Ce projet est distribué sous la [licence Apache 2.0](../LICENSE).
