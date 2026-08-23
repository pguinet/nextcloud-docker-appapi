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
| Caddy | `caddy:2-alpine` | Reverse proxy avec SSL automatique |
| Nextcloud | `nextcloud:32-apache` | Application principale |
| PostgreSQL | `postgres:16-alpine` | Base de données |
| Redis | `redis:7-alpine` | Cache et file locking |
| Cron | `nextcloud:32-apache` | Tâches planifiées + pré-génération des previews |
| Docker Socket Proxy | `tecnativa/docker-socket-proxy` | Proxy sécurisé pour AppAPI |

## Prérequis

* VPS avec Docker et Docker Compose installés
* Nom de domaine pointant vers le VPS
* Ports 80 et 443 ouverts

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

```bash
cp .env.example .env
nano .env
```

Modifiez les valeurs :

* `NEXTCLOUD_DOMAIN` : votre nom de domaine
* `POSTGRES_PASSWORD` : mot de passe fort pour PostgreSQL
* `NEXTCLOUD_ADMIN_USER` : nom d'utilisateur admin
* `NEXTCLOUD_ADMIN_PASSWORD` : mot de passe admin

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
marqueur de fin, pas seulement un gzip valide) puis renommé : un fichier au nom
définitif est toujours un dump complet. La rotation, par défaut à 14 jours,
n'a lieu qu'après un dump validé. Variables : `BACKUP_DIR`, `RETENTION_DAYS`,
`DB_CONTAINER`, `DB_NAME`, `MIN_FREE_MB`.

Pour l'automatiser, deux unités systemd sont fournies dans `systemd/` :

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
