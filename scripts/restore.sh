#!/bin/bash
# ===========================================
# Script de restauration Nextcloud
# ===========================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Vérifier les arguments
if [ -z "$1" ]; then
    log_error "Usage: $0 <chemin_vers_backup.tar.gz>"
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Fichier de backup non trouvé: $BACKUP_FILE"
    exit 1
fi

cd "$PROJECT_DIR"

# Confirmation
log_warn "=========================================="
log_warn "ATTENTION: Cette opération va restaurer"
log_warn "Nextcloud à partir du backup:"
log_warn "$BACKUP_FILE"
log_warn ""
log_warn "Les données actuelles seront ÉCRASÉES !"
log_warn "=========================================="
read -p "Continuer ? (oui/non) " -r
if [[ ! $REPLY =~ ^oui$ ]]; then
    log_info "Restauration annulée."
    exit 0
fi

# Créer un répertoire temporaire
TEMP_DIR=$(mktemp -d)
log_info "Extraction du backup dans $TEMP_DIR..."
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
BACKUP_DIR=$(ls "$TEMP_DIR")
BACKUP_PATH="${TEMP_DIR}/${BACKUP_DIR}"

# Vérifier le contenu du backup
if [ ! -f "${BACKUP_PATH}/database.sql" ]; then
    log_error "Backup invalide: database.sql manquant"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 1. Arrêter les services (sauf la DB)
log_info "Arrêt des services..."
docker compose stop nextcloud cron caddy || true

# 2. Activer le mode maintenance si Nextcloud tourne encore
docker compose exec -T -u www-data nextcloud php occ maintenance:mode --on 2>/dev/null || true

# 3. Restaurer la configuration Docker si présente
if [ -f "${BACKUP_PATH}/docker-compose.yml" ]; then
    log_info "Restauration de docker-compose.yml..."
    cp "${BACKUP_PATH}/docker-compose.yml" ./docker-compose.yml
fi

if [ -f "${BACKUP_PATH}/Caddyfile" ]; then
    log_info "Restauration du Caddyfile..."
    cp "${BACKUP_PATH}/Caddyfile" ./Caddyfile
fi

if [ -f "${BACKUP_PATH}/.env" ]; then
    log_warn "Un fichier .env existe dans le backup."
    read -p "Restaurer .env ? (oui/non) " -r
    if [[ $REPLY =~ ^oui$ ]]; then
        cp "${BACKUP_PATH}/.env" ./.env
    fi
fi

# 4. Restaurer les données utilisateurs
if [ -f "${BACKUP_PATH}/data.tar.gz" ]; then
    log_info "Restauration des fichiers utilisateurs..."
    rm -rf "${PROJECT_DIR}/data/nextcloud"
    mkdir -p "${PROJECT_DIR}/data"
    tar -xzf "${BACKUP_PATH}/data.tar.gz" -C "${PROJECT_DIR}/data"
fi

# 5. Démarrer la base de données
log_info "Démarrage de la base de données..."
docker compose up -d db
sleep 10

# 6. Restaurer la base de données
log_info "Restauration de la base de données..."
# Supprimer et recréer la base
docker compose exec -T db psql -U nextcloud -c "DROP DATABASE IF EXISTS nextcloud;" postgres
docker compose exec -T db psql -U nextcloud -c "CREATE DATABASE nextcloud;" postgres
# Importer
docker compose exec -T db psql -U nextcloud nextcloud < "${BACKUP_PATH}/database.sql"

# 7. Démarrer Nextcloud
log_info "Démarrage de Nextcloud..."
docker compose up -d nextcloud
sleep 15

# 8. Restaurer la configuration
if [ -f "${BACKUP_PATH}/config.tar.gz" ]; then
    log_info "Restauration de la configuration Nextcloud..."
    docker compose exec -T nextcloud tar -xzf - -C /var/www/html < "${BACKUP_PATH}/config.tar.gz"
fi

# 9. Corriger les permissions
log_info "Correction des permissions..."
docker compose exec -T nextcloud chown -R www-data:www-data /var/www/html/data
docker compose exec -T nextcloud chown -R www-data:www-data /var/www/html/config

# 10. Mettre à jour la base de données si nécessaire
log_info "Mise à jour de la base de données Nextcloud..."
docker compose exec -T -u www-data nextcloud php occ upgrade || true
docker compose exec -T -u www-data nextcloud php occ db:add-missing-indices || true
docker compose exec -T -u www-data nextcloud php occ db:add-missing-columns || true
docker compose exec -T -u www-data nextcloud php occ db:add-missing-primary-keys || true

# 11. Désactiver le mode maintenance
log_info "Désactivation du mode maintenance..."
docker compose exec -T -u www-data nextcloud php occ maintenance:mode --off

# 12. Démarrer tous les services
log_info "Démarrage de tous les services..."
docker compose up -d

# Nettoyage
rm -rf "$TEMP_DIR"

log_info "=========================================="
log_info "Restauration terminée avec succès !"
log_info "Vérifiez que Nextcloud fonctionne correctement."
log_info "=========================================="
