#!/bin/bash
# ===========================================
# Script d'installation initiale
# ===========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${CYAN}"
echo "=========================================="
echo "  Installation Nextcloud Docker + AppAPI"
echo "=========================================="
echo -e "${NC}"

cd "$PROJECT_DIR"

# Vérifier Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker n'est pas installé."
    log_info "Installez Docker avec: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose n'est pas disponible."
    exit 1
fi

log_info "Docker et Docker Compose sont installés ✓"

# Vérifier/créer .env
# docker-compose.yml pointe vers la variante choisie (MariaDB par défaut)
if grep -q 'dhi.io/mariadb' docker-compose.yml; then VARIANT=mariadb; else VARIANT=postgres; fi
if [ ! -f ".env" ]; then
    log_warn "Fichier .env non trouvé. Configuration interactive (variante ${VARIANT})..."
    echo ""
    scripts/generate-env.sh "$VARIANT" .env
    log_info "Fichier .env créé ✓ (secrets générés, droits 600)"
else
    log_info "Fichier .env existant trouvé ✓"
fi

# Créer les répertoires de données
log_info "Création des répertoires de données..."
mkdir -p data/nextcloud data/db data/redis backups
chmod 750 data

# Rendre les scripts exécutables
chmod +x scripts/*.sh

# MariaDB et Redis (images dhi.io) tournent en nonroot (uid 65532)
log_info "Attribution des répertoires db et redis à l'uid 65532..."
scripts/prepare-data-dirs.sh data

# Démarrer la stack
log_info "Démarrage de la stack Docker..."
docker compose pull
# L'image DHI de MariaDB ne crée ni la base ni l'utilisateur : le faire avant Nextcloud
if docker compose config --images | grep -q '^dhi.io/mariadb'; then
    docker compose up -d --wait db
    scripts/init-mariadb.sh
fi
docker compose up -d

log_info "En attente du démarrage de Nextcloud..."
echo -n "Patientez"
for i in {1..30}; do
    echo -n "."
    sleep 2
done
echo ""

# Vérifier le statut
if docker compose ps | grep -q "nextcloud.*running"; then
    log_info "Nextcloud est démarré ✓"
else
    log_warn "Nextcloud semble toujours en cours de démarrage..."
    log_info "Vérifiez les logs avec: docker compose logs -f nextcloud"
fi

# Afficher les informations, sans sourcer .env : un ancien .env aux valeurs
# non protégées (espaces, $) casserait le shell
env_get() { sed -n "s/^$1=//p" .env | tail -1 | sed -E "s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/"; }
NEXTCLOUD_DOMAIN=$(env_get NEXTCLOUD_DOMAIN)
NEXTCLOUD_ADMIN_USER=$(env_get NEXTCLOUD_ADMIN_USER)
echo ""
echo -e "${GREEN}=========================================="
echo "  Installation terminée !"
echo "==========================================${NC}"
echo ""
echo "URL:      https://${NEXTCLOUD_DOMAIN}"
echo "Admin:    ${NEXTCLOUD_ADMIN_USER}"
echo ""
echo -e "${YELLOW}Prochaines étapes :${NC}"
echo "1. Vérifiez que le DNS pointe vers ce serveur"
echo "2. Accédez à https://${NEXTCLOUD_DOMAIN}"
echo "3. Configurez AppAPI dans Administration → AppAPI"
echo ""
echo "Commandes utiles:"
echo "  docker compose logs -f    # Voir les logs"
echo "  docker compose ps         # État des services"
echo "  ./scripts/backup.sh       # Créer un backup"
echo ""
