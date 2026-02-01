#!/bin/bash
# ===========================================
# Script de backup Nextcloud
# ===========================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_DIR}/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="nextcloud_backup_${DATE}"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Vérifications
cd "$PROJECT_DIR"

if [ ! -f "docker-compose.yml" ]; then
    log_error "docker-compose.yml non trouvé dans $PROJECT_DIR"
    exit 1
fi

# Créer le répertoire de backup
mkdir -p "$BACKUP_DIR"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"
mkdir -p "$BACKUP_PATH"

log_info "Démarrage du backup Nextcloud..."
log_info "Destination: $BACKUP_PATH"

# 1. Activer le mode maintenance
log_info "Activation du mode maintenance..."
docker compose exec -T -u www-data nextcloud php occ maintenance:mode --on || true

# 2. Backup de la base de données
log_info "Backup de la base de données PostgreSQL..."
docker compose exec -T db pg_dump -U nextcloud nextcloud > "${BACKUP_PATH}/database.sql"

# 3. Backup des données Nextcloud
log_info "Backup des fichiers utilisateurs..."
tar -czf "${BACKUP_PATH}/data.tar.gz" -C "${PROJECT_DIR}/data" nextcloud

# 4. Backup de la configuration
log_info "Backup de la configuration Nextcloud..."
docker compose exec -T nextcloud tar -czf - -C /var/www/html config > "${BACKUP_PATH}/config.tar.gz"

# 5. Backup des fichiers du projet
log_info "Backup des fichiers de configuration Docker..."
cp docker-compose.yml "${BACKUP_PATH}/"
cp Caddyfile "${BACKUP_PATH}/"
cp .env "${BACKUP_PATH}/" 2>/dev/null || log_warn "Fichier .env non trouvé"

# 6. Désactiver le mode maintenance
log_info "Désactivation du mode maintenance..."
docker compose exec -T -u www-data nextcloud php occ maintenance:mode --off || true

# 7. Créer l'archive finale
log_info "Création de l'archive finale..."
cd "$BACKUP_DIR"
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_NAME"

# 8. Nettoyage des anciens backups (garder les 5 derniers)
log_info "Nettoyage des anciens backups..."
ls -t "${BACKUP_DIR}"/nextcloud_backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm

# Résumé
BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" | cut -f1)
log_info "=========================================="
log_info "Backup terminé avec succès !"
log_info "Fichier: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
log_info "Taille: ${BACKUP_SIZE}"
log_info "=========================================="
