# Nextcloud Docker avec AppAPI

Stack Docker complète pour déployer Nextcloud avec support AppAPI (ExApps) sur un VPS.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                         Caddy                                   │
│                    (reverse proxy + SSL)                        │
└───────────────────────────┬────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────────┐
│                       Nextcloud                                 │
│                       (Apache)                                  │
└─────┬──────────────┬──────────────┬────────────────────────────┘
      │              │              │
┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────────────────┐
│ PostgreSQL│  │   Redis   │  │  Docker Socket Proxy  │
└───────────┘  └───────────┘  └─────────┬─────────────┘
                                        │
                              ┌─────────▼─────────────┐
                              │   Conteneurs ExApps   │
                              │ (Assistant, Recognize)│
                              └───────────────────────┘
```

## Composants

| Service | Image | Rôle |
| --- | --- | --- |
| Caddy | `caddy/Dockerfile` (`dhi.io/caddy` + Coraza) | Reverse proxy avec SSL automatique, filtre IP et WAF |
| Nextcloud | `nextcloud:32-apache` | Application principale |
| MariaDB | `dhi.io/mariadb:11.8` | Base de données (variante MariaDB) |
| PostgreSQL | `postgres:16-alpine` | Base de données (variante PostgreSQL) |
| Redis | `dhi.io/redis:7` | Cache et file locking |
| Cron | `nextcloud:32-apache` | Tâches planifiées + pré-génération des previews |
| Docker Socket Proxy | `tecnativa/docker-socket-proxy` | Proxy sécurisé pour AppAPI |

## Prérequis

* VPS avec Docker et Docker Compose installés
* Nom de domaine pointant vers le VPS
* Ports 80 et 443 ouverts
* Un compte Docker Hub (gratuit) et `docker login dhi.io` : Caddy, MariaDB et Redis utilisent les [Docker Hardened Images](#images-docker-hardened-images-caddy-mariadb-redis), dont le téléchargement exige d'être authentifié

### Installation Docker (Debian/Ubuntu)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

## Installation

### 1. Cloner le projet

```bash
git clone https://github.com/pguinet/nextcloud-docker-appapi.git
cd nextcloud-docker-appapi
```

### 2. Configurer l'environnement

`scripts/install.sh` génère le `.env` s'il n'existe pas (`scripts/generate-env.sh`) : il demande le domaine, le compte admin et les IP autorisées, puis génère les mots de passe de la base et la clé HaRP.

Pour l'écrire à la main :

```bash
cp .env.example .env && chmod 600 .env
nano .env
```

Modifiez les valeurs :

* `NEXTCLOUD_DOMAIN` : votre nom de domaine
* `NEXTCLOUD_ALLOWED_IPS` : IP ou plages autorisées, entre apostrophes (vide = aucun accès depuis Internet)
* `MYSQL_PASSWORD` et `MYSQL_ROOT_PASSWORD` (MariaDB) ou `POSTGRES_PASSWORD` (PostgreSQL) : mots de passe forts
* `HARP_SHARED_KEY` : `openssl rand -hex 32`
* `NEXTCLOUD_ADMIN_USER` : nom d'utilisateur admin
* `NEXTCLOUD_ADMIN_PASSWORD` : mot de passe admin

Une valeur qui contient des espaces ou un `$` doit être entre apostrophes.

### 3. Créer les scripts custom

Les hooks personnalisés permettent d'installer des dépendances supplémentaires et de personnaliser le comportement du cron.

```bash
mkdir -p /data/nextcloud/hooks
```

#### install-ffmpeg.sh

Ce script installe `ffmpeg` dans les conteneurs Nextcloud au démarrage. Il est nécessaire pour la génération des miniatures vidéo et le rendu vidéo de l'app Journeys.

Créer le fichier `/data/nextcloud/hooks/install-ffmpeg.sh` :

```bash
#!/bin/bash
if ! command -v ffmpeg &> /dev/null; then
    apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
fi
```

```bash
chmod +x /data/nextcloud/hooks/install-ffmpeg.sh
```

#### cron-custom.sh

Ce script remplace l'entrypoint par défaut du conteneur cron. Il exécute les tâches planifiées Nextcloud (cron.php) ainsi que la pré-génération incrémentale des previews (nécessite l'app `previewgenerator`) toutes les 5 minutes.

Créer le fichier `/data/nextcloud/hooks/cron-custom.sh` :

```bash
#!/bin/bash
# Installation de ffmpeg si absent
/custom-hooks/install-ffmpeg.sh

while true; do
    php -f /var/www/html/cron.php
    php /var/www/html/occ preview:pre-generate
    sleep 300
done
```

```bash
chmod +x /data/nextcloud/hooks/cron-custom.sh
```

### 4. Lancer la stack

```bash
docker compose up -d
```

### 5. Vérifier les logs

```bash
docker compose logs -f nextcloud
```

Attendez que l'installation soit terminée (quelques minutes au premier démarrage).

## Configuration du conteneur Cron

Le conteneur cron utilise un script custom qui combine les background jobs Nextcloud et la pré-génération des previews. Il monte le répertoire des hooks pour accéder aux scripts :

```yaml
cron:
  image: nextcloud:${NEXTCLOUD_VERSION:-32}-apache
  container_name: nextcloud-cron
  restart: unless-stopped
  depends_on:
    - nextcloud
  entrypoint: /bin/bash
  command: /custom-hooks/cron-custom.sh
  volumes:
    - nextcloud_html:/var/www/html
    - ${DATA_PATH:-./data}/nextcloud:/var/www/html/data
    - /data/nextcloud/hooks:/custom-hooks
  networks:
    - backend
```

Le conteneur Nextcloud principal doit également monter le hook ffmpeg :

```yaml
nextcloud:
  image: nextcloud:${NEXTCLOUD_VERSION:-32}-apache
  # ...
  volumes:
    - nextcloud_html:/var/www/html
    - ${DATA_PATH:-./data}/nextcloud:/var/www/html/data
    - /data/nextcloud/hooks/install-ffmpeg.sh:/docker-entrypoint-hooks.d/before-starting/install-ffmpeg.sh
```

## Configuration AppAPI

Une fois Nextcloud accessible :

1. Connectez-vous en admin
2. Allez dans **Administration → AppAPI → Deploy Daemons**
3. Cliquez sur **Register Daemon**
4. Configurez :

| Champ | Valeur |
| --- | --- |
| Name | `docker-local` |
| Display name | `Docker Local` |
| Deployment method | Docker Socket Proxy |
| Daemon Host | `docker-socket-proxy:2375` |
| Network | Voir ci-dessous |
| Enable HTTPS | Non |

Pour trouver le nom du réseau :

```bash
docker network ls | grep backend
```

Le nom sera de la forme `nextcloud-docker-appapi_backend`.

### Installer des ExApps

Après configuration du daemon, allez dans **Applications → ExApps** pour installer :

* Nextcloud Assistant
* Context Chat
* Recognize
* Whisper Speech-to-Text

## Apps recommandées pour la gestion de photos

### Memories

App de gestion avancée de photos avec timeline, reconnaissance faciale et géolocalisation.

```bash
docker exec -u www-data nextcloud-app php occ app:install memories
docker exec -u www-data nextcloud-app php occ memories:places-setup --force
docker exec -u www-data nextcloud-app php occ memories:index
```

### Journeys

Clustering automatique des photos en voyages/sorties avec création d'albums et de vidéos souvenirs. Nécessite Memories et ffmpeg.

```bash
docker exec -u www-data nextcloud-app php occ app:install journeys
docker exec -u www-data nextcloud-app php occ journeys:cluster-create-albums <user>
```

### Preview Generator

Pré-génération des miniatures pour une navigation fluide. La pré-génération incrémentale est intégrée au cron custom.

```bash
docker exec -u www-data nextcloud-app php occ app:install previewgenerator
# Génération initiale (peut être long)
docker exec -u www-data nextcloud-app php occ preview:generate-all
```

Pour activer les previews vidéo, ajouter le provider Movie dans la configuration :

```bash
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 0 --value="OC\Preview\PNG"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 1 --value="OC\Preview\JPEG"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 2 --value="OC\Preview\GIF"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 3 --value="OC\Preview\BMP"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 4 --value="OC\Preview\XBitmap"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 5 --value="OC\Preview\MP3"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 6 --value="OC\Preview\TXT"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 7 --value="OC\Preview\MarkDown"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 8 --value="OC\Preview\Movie"
```

## Commandes utiles

### Gestion de la stack

```bash
# Démarrer
docker compose up -d

# Arrêter
docker compose down

# Redémarrer un service
docker compose restart nextcloud

# Voir les logs
docker compose logs -f [service]

# Mise à jour des images
docker compose pull
docker compose up -d
```

### Commandes OCC (Nextcloud)

```bash
# Exécuter une commande occ
docker compose exec -u www-data nextcloud php occ [commande]

# Exemples
docker compose exec -u www-data nextcloud php occ status
docker compose exec -u www-data nextcloud php occ maintenance:mode --on
docker compose exec -u www-data nextcloud php occ db:add-missing-indices
docker compose exec -u www-data nextcloud php occ files:scan --all
```

### Backup

Sauvegarde de la **base de données** seule, adaptée au moteur en place
(MariaDB ou PostgreSQL) :

```bash
./scripts/backup-db.sh
```

Le dump est écrit dans `/data/nextcloud/db-backups/`, vérifié (présence du
marqueur de fin, pas seulement une archive lisible) puis renommé : un fichier au
nom définitif est toujours un dump complet. La rotation, par défaut à 35 jours,
n'a lieu qu'après un dump validé. Variables : `BACKUP_DIR`, `RETENTION_DAYS`,
`DB_CONTAINER`, `DB_NAME`, `MIN_FREE_MB`, `COMPRESSOR`.

La compression par défaut est **xz**, qui gagne environ 40 % sur gzip pour un
dump SQL. Le prix à payer est un pic de ~1 Go de RAM et quelques minutes de
CPU ; `COMPRESSOR=gzip` revient au comportement rapide.

`EXCLUDE_TABLES` retire les **données** de certaines tables tout en conservant
leur **structure** : la restauration les recrée vides. Par défaut, les tables
planet de l'app Memories — des données OpenStreetMap statiques, sans rien
d'utilisateur, régénérées par `occ memories:places-setup`. Elles pèsent à elles
seules plus des trois quarts du dump :

| Dump | Brut | xz |
|------|------|-----|
| intégral | 609 Mo | 84 Mo |
| sans les tables planet | 101 Mo | **15 Mo** |

N'y ajouter que des données reconstructibles sans perte. `oc_filecache`, malgré
sa taille, n'est pas candidate : les partages référencent les `fileid`, qu'un
rescan réattribuerait — les partages seraient rompus. `EXCLUDE_TABLES=` produit
un dump intégral.

**Après restauration**, régénérer les données exclues :

```bash
docker compose exec -u www-data nextcloud php occ memories:places-setup
```

Pour l'automatiser, deux unités systemd sont fournies dans `systemd/` — la
sauvegarde est **hebdomadaire** (dimanche 3h UTC) :

```bash
sudo cp systemd/nextcloud-backup-db.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-backup-db.timer
systemctl list-timers nextcloud-backup-db.timer   # prochaine exécution
journalctl -u nextcloud-backup-db.service         # dernier compte rendu
```

> **Les fichiers utilisateurs ne sont pas couverts par ce script.** Il ne
> sauvegarde que la base ; prévoyez un mécanisme distinct pour `data/nextcloud`
> (synchronisation externe, instantanés, stockage objet…). Et un dump posé sur
> le disque qu'il protège ne protège de rien : visez une destination qui quitte
> la machine.
>
> **Rythme hebdomadaire = jusqu'à 7 jours de base perdus** en cas de sinistre.
> Les fichiers, répliqués en continu par ailleurs, ne sont pas concernés ; en
> revanche calendriers, contacts, partages et commentaires n'existent que dans
> la base. Passer à `OnCalendar=*-*-* 03:00:00` pour un rythme quotidien.
>
> Si la destination est un stockage objet synchronisé, vérifiez que la
> suppression se propage : sans cela la rotation locale ne sert à rien et les
> dumps s'accumulent indéfiniment côté distant. Une règle de cycle de vie sur
> le bucket est plus fiable qu'un espoir de synchronisation.

Le script historique `./scripts/backup.sh` sauvegarde base **et** fichiers,
mais il est écrit pour PostgreSQL (`pg_dump`) : il échoue sur une installation
MariaDB.

### Restauration

```bash
./scripts/restore.sh /chemin/vers/backup.tar.gz
```

## Structure des données

```
data/
├── nextcloud/          # Fichiers utilisateurs
│   └── hooks/          # Scripts custom
│       ├── install-ffmpeg.sh   # Installation ffmpeg au démarrage
│       └── cron-custom.sh      # Cron personnalisé (background jobs + previews)
├── db/                 # Données de la base (PostgreSQL ou MariaDB)
└── redis/              # Données Redis
```

## Optimisations recommandées

### 1. Configuration PHP (post-installation)

Éditez `config/config.php` dans le volume nextcloud :

```php
'memcache.local' => '\\OC\\Memcache\\APCu',
'memcache.distributed' => '\\OC\\Memcache\\Redis',
'memcache.locking' => '\\OC\\Memcache\\Redis',
'redis' => [
    'host' => 'redis',
    'port' => 6379,
],
'default_phone_region' => 'FR',
'maintenance_window_start' => 1,
```

### 2. Cron système

Vérifiez que le cron fonctionne :

```bash
docker compose logs cron
```

Dans Administration → Paramètres de base, sélectionnez "Cron" comme méthode de tâches de fond.

## Dépannage

### Erreur "Access denied" AppAPI

Vérifiez que le Docker Socket Proxy est accessible :

```bash
docker compose exec nextcloud curl http://docker-socket-proxy:2375/version
```

### Problèmes de permissions

```bash
docker compose exec nextcloud chown -R www-data:www-data /var/www/html/data
```

### Nextcloud en mode maintenance

```bash
docker compose exec -u www-data nextcloud php occ maintenance:mode --off
```

### Pas de miniatures vidéo

Vérifiez que ffmpeg est installé et que le preview provider Movie est activé :

```bash
docker exec nextcloud-app which ffmpeg
docker exec -u www-data nextcloud-app php occ config:system:get enabledPreviewProviders
```

### Erreur Journeys "Could not resolve AlbumMapper"

L'app Memories doit être installée et activée. Journeys dépend de Memories même si ce n'est pas listé explicitement dans les dépendances Nextcloud :

```bash
docker exec -u www-data nextcloud-app php occ app:install memories
docker exec -u www-data nextcloud-app php occ memories:places-setup --force
docker exec -u www-data nextcloud-app php occ memories:index
```

## Sécurité

* Le Docker Socket Proxy filtre les appels API autorisés
* Caddy gère automatiquement les certificats SSL
* Les mots de passe sont dans `.env` (non versionné)
* Le réseau `backend` isole les services internes

### Filtre IP

Caddy n'accepte que les adresses listées dans `NEXTCLOUD_ALLOWED_IPS` (fichier `.env`), séparées par des espaces, en IPv4 comme en IPv6 :

```bash
NEXTCLOUD_ALLOWED_IPS=203.0.113.10 2001:db8:1234:5600::/56
```

Le réseau `backend` reste toujours autorisé : Nextcloud et les ExApps appellent l'URL publique, et un alias réseau sur `backend` les envoie directement vers Caddy. Son sous-réseau est fixé (`NEXTCLOUD_BACKEND_SUBNET`, `172.18.0.0/16` par défaut) ; sa passerelle (`NEXTCLOUD_BACKEND_GATEWAY`) est exclue, car c'est l'hôte et le trafic relayé par `docker-proxy` y apparaît. Les autres réseaux privés, y compris `frontend`, sont refusés. Toute autre adresse reçoit un `403`, y compris sur `/exapps/*`. Sans variable, plus rien n'est joignable depuis Internet. Les challenges Let's Encrypt ne sont pas concernés.

Le réseau `frontend` a l'IPv6 activé : sans lui, les clients IPv6 passent par `docker-proxy` et Caddy ne voit que l'IP de la passerelle Docker, ce qui fausse le filtre.

Après modification de `.env` : `docker compose up -d caddy`.

#### Sondes UptimeRobot

Les [sondes UptimeRobot](https://uptimerobot.com/help/locations/) sont autorisées, mais uniquement en `GET`/`HEAD` sur `/status.php` : un monitor doit pointer sur `https://<domaine>/status.php`. Leurs adresses sont dans `caddy/uptimerobot-ips.caddy`, généré à partir de la liste officielle. Cette liste évolue ; si des sondes se font refuser, la régénérer puis recharger Caddy :

```bash
./scripts/update-uptimerobot-ips.sh
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### WAF (Coraza + OWASP CRS)

Caddy embarque le WAF [Coraza](https://coraza.io/) avec l'[OWASP Core Rule Set](https://coreruleset.org/) et le [plugin d'exclusions Nextcloud](https://github.com/coreruleset/nextcloud-rule-exclusions-plugin), en mode bloquant (paranoia level 1).

* Le corps des uploads WebDAV n'est pas inspecté (fichiers jusqu'à `PHP_UPLOAD_LIMIT`) ; l'URL et les en-têtes le sont.
* Les autres requêtes sont limitées à 12,5 Mo de corps.
* `/exapps/*` (HaRP) ne passe pas par le WAF.
* Les réglages locaux sont dans `caddy/coraza/nextcloud.conf`, monté en lecture seule.

Les versions de Caddy, du module Coraza et du plugin sont épinglées dans `caddy/Dockerfile`. Pour les mettre à jour : `docker compose build --pull caddy && docker compose up -d caddy`.

Les blocages apparaissent dans les logs de Caddy :

```bash
docker compose logs caddy | grep -E 'Access denied|rule violation'
```

En cas de faux positif, repérer le `unique_id` de la requête, retrouver les règles déclenchées (`grep <unique_id>`), puis ajouter une exclusion ciblée dans `caddy/coraza/nextcloud.conf` (par exemple `ctl:ruleRemoveTargetById` limité à une URL) et recharger :

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Le banc de test `tests/caddy-waf/run.sh` vérifie le filtre IP, les blocages du WAF et le passage du trafic Nextcloud (WebDAV, CalDAV, OCS, gros uploads). Le relancer après toute modification du `Caddyfile` ou de la configuration Coraza.

## Images Docker Hardened Images (Caddy, MariaDB, Redis)

Caddy, MariaDB et Redis utilisent les [Docker Hardened Images](https://hub.docker.com/hardened-images/catalog) (`dhi.io/caddy`, `dhi.io/mariadb:11.8`, `dhi.io/redis:7`) : images minimales, sans gestionnaire de paquets, peu de CVE, avec SBOM et provenance signée. Le téléchargement exige `docker login dhi.io` avec un compte Docker Hub.

Elles ne se comportent pas comme les images officielles :

* **Utilisateur nonroot (uid 65532)** : elles ne peuvent pas s'approprier leurs données. `scripts/prepare-data-dirs.sh` donne à cet uid `db/`, `redis/` et les volumes Caddy existants (appelé par `install.sh`).
* **MariaDB ignore les arguments de `command`** : les options du serveur passent par `MARIADB_OPTIONS`.
* **MariaDB ne crée que le compte root** : `MYSQL_DATABASE`, `MYSQL_USER` et `MYSQL_PASSWORD` sont ignorés. `scripts/init-mariadb.sh` crée la base et l'utilisateur (appelé par `install.sh`, idempotent).
* **Redis n'a pas d'entrypoint** : `--protected-mode no` doit être passé explicitement, sinon les clients hors loopback sont refusés.
* **Caddy n'inclut pas Coraza** : `caddy/Dockerfile` compile toujours le binaire avec xcaddy dans l'image officielle `caddy:*-builder`, puis le copie dans l'image DHI. Celle-ci n'a pas de shell (pas de `RUN`) et a `caddy` pour entrypoint : `docker run nextcloud-caddy-waf validate …`, et non `… caddy validate …`. `docker compose exec caddy caddy reload` fonctionne comme avant.

Le banc de test `tests/db-redis/run.sh` vérifie une installation neuve et la reprise de données créées par les images officielles ; `tests/caddy-waf/run.sh` vérifie aussi que Caddy tourne en nonroot et écrit son log d'accès.

### Migrer MariaDB et Redis depuis les images officielles

Les versions majeures sont identiques (MariaDB 11.8, Redis 7.4) : aucune conversion de données, seul le propriétaire des fichiers change (999 → 65532).

```bash
docker login dhi.io
./scripts/backup-db.sh

docker compose stop cron nextcloud
docker compose stop db redis
./scripts/prepare-data-dirs.sh "${DATA_PATH:-./data}"
docker compose up -d
```

Retour arrière : annuler le commit (`git revert`, qui remet aussi les options MariaDB dans `command`), puis `sudo chown -R 999:999 <DATA_PATH>/db <DATA_PATH>/redis` avant `docker compose up -d`.

### Migrer Caddy depuis l'image officielle

Les volumes `nextcloud_caddy_data` (certificats, logs) et `nextcloud_caddy_config` appartiennent à root : sans changement de propriétaire, Caddy DHI ne démarre pas. Les certificats existants sont repris tels quels, sans nouvelle demande à Let's Encrypt.

```bash
docker compose build --pull caddy
docker compose stop caddy
./scripts/prepare-data-dirs.sh "${DATA_PATH:-./data}"
docker compose up -d caddy
```

Retour arrière : annuler le commit, `docker compose build caddy && docker compose up -d caddy`. L'image officielle tourne en root et lit les volumes quel que soit leur propriétaire.

## Mise à jour de Nextcloud

```bash
# Backup d'abord !
./scripts/backup-db.sh

# Mettre à jour l'image
docker compose pull nextcloud
docker compose up -d

# Finaliser la mise à jour
docker compose exec -u www-data nextcloud php occ upgrade
docker compose exec -u www-data nextcloud php occ maintenance:mode --off
```

## Licence

MIT

## Contribution

Les PR sont les bienvenues !
