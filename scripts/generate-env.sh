#!/bin/bash
# ===========================================
# Génère le fichier .env de la stack (appelé par install.sh)
# ===========================================
# Pose les questions (domaine, admin, IP autorisées) sur l'entrée standard et
# génère les secrets : mots de passe de la base, clé partagée HaRP.
# Les valeurs sont écrites entre apostrophes : Compose comme bash les lisent
# telles quelles, espaces et $ compris.
#
# Usage : scripts/generate-env.sh <mariadb|postgres> [fichier]   (défaut : .env)

set -euo pipefail

VARIANT=${1:-}
OUT=${2:-.env}

case $VARIANT in
    mariadb|postgres) ;;
    *) echo "Usage : $0 <mariadb|postgres> [fichier]" >&2; exit 2 ;;
esac
if [ -e "$OUT" ]; then
    echo "$OUT existe déjà : rien n'est écrasé." >&2
    exit 1
fi

# Entre apostrophes, une apostrophe ne peut pas être échappée (ni par Compose, ni par bash)
quote() {
    case $1 in
        *"'"*) echo "L'apostrophe n'est pas acceptée dans les valeurs." >&2; exit 1 ;;
    esac
    printf "'%s'" "$1"
}
random_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }

read -r -p "Nom de domaine Nextcloud (ex: cloud.example.com): " DOMAIN
[ -n "$DOMAIN" ] || { echo "Le domaine est obligatoire." >&2; exit 1; }
read -r -p "Nom d'utilisateur admin [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -r -s -p "Mot de passe admin: " ADMIN_PASS
echo >&2
[ -n "$ADMIN_PASS" ] || { echo "Le mot de passe admin est obligatoire." >&2; exit 1; }
echo "IP ou plages CIDR autorisées à joindre Nextcloud, séparées par des espaces" >&2
read -r -p "(pensez à l'IPv6 ; vide = aucun accès depuis Internet): " ALLOWED_IPS
[ -n "$ALLOWED_IPS" ] || echo "Attention : sans IP autorisée, Nextcloud ne sera joignable que depuis le serveur." >&2

# Contrôler les valeurs avant d'écrire quoi que ce soit
for value in "$DOMAIN" "$ADMIN_USER" "$ADMIN_PASS" "$ALLOWED_IPS"; do
    quote "$value" >/dev/null
done

umask 077
{
    echo "# Généré par scripts/generate-env.sh le $(date '+%F %T') : voir .env.example"
    echo "NEXTCLOUD_DOMAIN=$(quote "$DOMAIN")"
    echo "NEXTCLOUD_ALLOWED_IPS=$(quote "$ALLOWED_IPS")"
    echo "NEXTCLOUD_ADMIN_USER=$(quote "$ADMIN_USER")"
    echo "NEXTCLOUD_ADMIN_PASSWORD=$(quote "$ADMIN_PASS")"
    echo "HARP_SHARED_KEY=$(openssl rand -hex 32)"
    if [ "$VARIANT" = mariadb ]; then
        echo "MYSQL_DATABASE=nextcloud"
        echo "MYSQL_USER=nextcloud"
        echo "MYSQL_PASSWORD=$(random_password)"
        echo "MYSQL_ROOT_PASSWORD=$(random_password)"
    else
        echo "POSTGRES_DB=nextcloud"
        echo "POSTGRES_USER=nextcloud"
        echo "POSTGRES_PASSWORD=$(random_password)"
    fi
    echo "PHP_MEMORY_LIMIT=1G"
    echo "PHP_UPLOAD_LIMIT=10G"
} > "$OUT"
