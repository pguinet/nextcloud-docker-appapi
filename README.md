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
|---------|-------|------|
| Caddy | `caddy:2-alpine` | Reverse proxy avec SSL automatique |
| Nextcloud | `nextcloud:30-apache` | Application principale |
| PostgreSQL | `postgres:16-alpine` | Base de données |
| Redis | `redis:7-alpine` | Cache et file locking |
| Cron | `nextcloud:30-apache` | Tâches planifiées |
| Docker Socket Proxy | `tecnativa/docker-socket-proxy` | Proxy sécurisé pour AppAPI |

## Prérequis

- VPS avec Docker et Docker Compose installés
- Nom de domaine pointant vers le VPS
- Ports 80 et 443 ouverts

### Installation Docker (Debian/Ubuntu)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

## Installation

### 1. Cloner le projet

```bash
git clone https://github.com/VOTRE_USER/nextcloud-docker-appapi.git
cd nextcloud-docker-appapi
```

### 2. Configurer l'environnement

```bash
cp .env.example .env
nano .env
```

Modifiez les valeurs :
- `NEXTCLOUD_DOMAIN` : votre nom de domaine
- `POSTGRES_PASSWORD` : mot de passe fort pour PostgreSQL
- `NEXTCLOUD_ADMIN_USER` : nom d'utilisateur admin
- `NEXTCLOUD_ADMIN_PASSWORD` : mot de passe admin

### 3. Lancer la stack

```bash
docker compose up -d
```

### 4. Vérifier les logs

```bash
docker compose logs -f nextcloud
```

Attendez que l'installation soit terminée (quelques minutes au premier démarrage).

## Configuration AppAPI

Une fois Nextcloud accessible :

1. Connectez-vous en admin
2. Allez dans **Administration → AppAPI → Deploy Daemons**
3. Cliquez sur **Register Daemon**
4. Configurez :

| Champ | Valeur |
|-------|--------|
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
- Nextcloud Assistant
- Context Chat
- Recognize
- Whisper Speech-to-Text

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

```bash
./scripts/backup.sh
```

### Restauration

```bash
./scripts/restore.sh /chemin/vers/backup.tar.gz
```

## Structure des données

```
data/
├── nextcloud/     # Fichiers utilisateurs
├── db/            # Données PostgreSQL
└── redis/         # Données Redis
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

## Sécurité

- Le Docker Socket Proxy filtre les appels API autorisés
- Caddy gère automatiquement les certificats SSL
- Les mots de passe sont dans `.env` (non versionné)
- Le réseau `backend` isole les services internes

## Mise à jour de Nextcloud

```bash
# Backup d'abord !
./scripts/backup.sh

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
