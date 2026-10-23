#!/bin/bash
# ===========================================
# Prépare les répertoires de données de MariaDB et Redis
# ===========================================
# Les images Docker Hardened Images (dhi.io) de MariaDB et Redis tournent en
# nonroot (uid 65532) : contrairement aux images officielles, elles ne peuvent
# pas s'approprier un répertoire créé par un autre utilisateur (root, 999...).
#
# Usage : scripts/prepare-data-dirs.sh [DATA_PATH]   (défaut : $DATA_PATH ou ./data)
# Idempotent. À lancer conteneurs db et redis arrêtés lors d'une migration.

set -euo pipefail

DHI_UID=65532
# Image déjà requise par la stack et qui contient chown (l'image Redis n'en a pas)
TOOLS_IMAGE=dhi.io/mariadb:11.8

DATA=${1:-${DATA_PATH:-./data}}
mkdir -p "$DATA/db" "$DATA/redis"

if ! docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1 \
        && ! docker pull -q "$TOOLS_IMAGE" >/dev/null; then
    echo "Impossible de télécharger $TOOLS_IMAGE : lancez 'docker login dhi.io' (compte Docker Hub)." >&2
    exit 1
fi

docker run --rm --user 0 --entrypoint chown \
    -v "$(realpath "$DATA/db"):/db" \
    -v "$(realpath "$DATA/redis"):/redis" \
    "$TOOLS_IMAGE" -R "$DHI_UID:$DHI_UID" /db /redis
