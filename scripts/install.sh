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
if [ ! -f ".env" ]; then
    if [ ! -f ".env.example" ]; then
        log_error ".env.example non trouvé"
        exit 1
    fi
    
    log_warn "Fichier .env non trouvé. Configuration interactive..."
    echo ""
    
    read -p "Nom de domaine Nextcloud (ex: cloud.example.com): " DOMAIN
    read -p "Nom d'utilisateur admin [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    read -s -p "Mot de passe admin: " ADMIN_PASS
    echo ""
    
    # Générer un mot de passe DB aléatoire
    DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    
    cat > .env << EOF
NEXTCLOUD_DOMAIN=${DOMAIN}
NEXTCLOUD_VERSION=30
NEXTCLOUD_ADMIN_USER=${ADMIN_USER}
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASS}
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=${DB_PASS}
PHP_MEMORY_LIMIT=1G
PHP_UPLOAD_LIMIT=10G
EOF
    
    log_info "Fichier .env créé ✓"
else
    log_info "Fichier .env existant trouvé ✓"
fi

# Créer les répertoires de données
log_info "Création des répertoires de données..."
mkdir -p data/nextcloud data/db data/redis backups
chmod 750 data

# Rendre les scripts exécutables
chmod +x scripts/*.sh

# Démarrer la stack
log_info "Démarrage de la stack Docker..."
docker compose pull
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

# Afficher les informations
source .env
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
