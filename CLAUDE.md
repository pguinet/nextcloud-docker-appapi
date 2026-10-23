# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Production-ready Docker stack for deploying Nextcloud with AppAPI (ExApps) support. Enables running external applications like Nextcloud Assistant, Context Chat, Recognize, and Whisper Speech-to-Text.

**Language**: Documentation in French, code comments bilingual.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                         Caddy                                   │
│                    (reverse proxy + SSL)                        │
└──────────┬────────────────────────────┬───────────────────────┘
           │                            │
           │ /exapps/*                  │ /*
           ▼                            ▼
┌──────────────────┐  ┌─────────────────────────────────────────┐
│      HaRP        │  │              Nextcloud                   │
│  (AppAPI proxy)  │  │              (Apache)                    │
└────────┬─────────┘  └─────┬──────────────┬────────────────────┘
         │                  │              │
         │            ┌─────▼─────┐  ┌─────▼─────┐
         │            │ DB (PG or │  │   Redis   │
         │            │ MariaDB)  │  │           │
         │            └───────────┘  └───────────┘
         │
┌────────▼───────────────┐
│   ExApp Containers     │
│   (via FRP tunnel)     │
└────────────────────────┘
```

**Networks**:
- `frontend`: Caddy ↔ Nextcloud, Caddy ↔ HaRP
- `backend`: Internal services (Nextcloud, DB, Redis, HaRP, Cron)

## Common Commands

### Stack Management
```bash
# Install (interactive setup)
./scripts/install.sh

# Start/Stop
docker compose up -d
docker compose down

# Logs
docker compose logs -f [service]
docker compose ps
```

### Nextcloud OCC Commands
```bash
docker compose exec -u www-data nextcloud php occ [command]

# Examples
docker compose exec -u www-data nextcloud php occ status
docker compose exec -u www-data nextcloud php occ maintenance:mode --on
docker compose exec -u www-data nextcloud php occ maintenance:mode --off
docker compose exec -u www-data nextcloud php occ db:add-missing-indices
docker compose exec -u www-data nextcloud php occ files:scan --all
```

### Backup/Restore
```bash
./scripts/backup.sh
./scripts/restore.sh /path/to/backup.tar.gz
```

### Update Nextcloud
```bash
./scripts/backup.sh
docker compose pull nextcloud
docker compose up -d
docker compose exec -u www-data nextcloud php occ upgrade
docker compose exec -u www-data nextcloud php occ maintenance:mode --off
```

## Key Files

| File | Purpose |
|------|---------|
| `docker-compose.postgres.yml` | Service orchestration - PostgreSQL variant |
| `docker-compose.mariadb.yml` | Service orchestration - MariaDB variant |
| `Caddyfile` | Reverse proxy with SSL and security headers |
| `.env.example` | Environment variable template |
| `scripts/install.sh` | Interactive initial setup |
| `scripts/generate-env.sh` | Generate `.env` for a variant (prompts + secrets, values single-quoted, mode 600); test: `tests/install/run.sh` |
| `scripts/backup.sh` | Full backup automation |
| `scripts/restore.sh` | Backup restoration |
| `scripts/prepare-data-dirs.sh` | Chown `db/`, `redis/` and Caddy volumes to uid 65532 (DHI images run nonroot) |
| `scripts/init-mariadb.sh` | Create Nextcloud DB + user (DHI MariaDB ignores `MYSQL_DATABASE`/`MYSQL_USER`) |

## Data Layout

```
data/
├── nextcloud/     # User files
├── db/            # PostgreSQL data
└── redis/         # Redis persistence
backups/           # Backup archives
```

All `data/` and `backups/` directories are gitignored.

## AppAPI Configuration (HaRP)

After Nextcloud is running, configure the AppAPI daemon with HaRP:

```bash
# IMPORTANT : nc-url doit être l'URL publique (passant par Caddy → HaRP),
# et non l'URL interne http://nextcloud (sinon les heartbeat ExApps échouent en 404).
docker compose exec -u www-data nextcloud php occ app_api:daemon:register \
  docker-local "Docker Local" docker-install \
  http appapi-harp:8780 "https://${NEXTCLOUD_DOMAIN}" \
  --net nextcloud_backend \
  --harp \
  --harp_frp_address appapi-harp:8782 \
  --harp_shared_key "${HARP_SHARED_KEY}" \
  --set-default
```

## Docker Hardened Images (Caddy, MariaDB, Redis)

`caddy`, `db` and `redis` use `dhi.io/caddy`, `dhi.io/mariadb:11.8` and `dhi.io/redis:7`; pulling needs `docker login dhi.io`. They differ from the official images:
- run as uid 65532 → data dirs and Caddy volumes must be chowned (`scripts/prepare-data-dirs.sh`)
- MariaDB ignores `command` args → server options go in `MARIADB_OPTIONS`
- MariaDB only creates root → `scripts/init-mariadb.sh` creates the DB and user
- Redis has no entrypoint → `--protected-mode no` must be explicit
- DHI Caddy has no Coraza → `caddy/Dockerfile` builds with xcaddy in the official builder and copies the binary; the final image has no shell (no `RUN`) and `caddy` as entrypoint

Test benches: `tests/db-redis/run.sh` (fresh install + migration from official images), `tests/caddy-waf/run.sh`.

## Environment Variables

Key variables in `.env`:
- `NEXTCLOUD_DOMAIN`: Domain for SSL certificate
- `NEXTCLOUD_VERSION`: Nextcloud image tag (default: 32)
- `HARP_SHARED_KEY`: Shared key for HaRP ↔ AppAPI authentication
- `POSTGRES_PASSWORD` / `MYSQL_PASSWORD`: Database password (auto-generated by install.sh)
- `PHP_MEMORY_LIMIT`: PHP memory (default: 1G)
- `PHP_UPLOAD_LIMIT`: Max upload size (default: 10G)

## Troubleshooting

```bash
# Test HaRP connection
docker compose exec nextcloud curl http://appapi-harp:8780/status

# Fix permissions
docker compose exec nextcloud chown -R www-data:www-data /var/www/html/data

# Exit maintenance mode
docker compose exec -u www-data nextcloud php occ maintenance:mode --off
```
