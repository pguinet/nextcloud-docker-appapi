#!/usr/bin/env bash
#
# Sauvegarde de la base de données Nextcloud (MariaDB ou PostgreSQL).
#
# Ne sauvegarde QUE la base : les fichiers utilisateurs de /data/nextcloud sont
# supposés couverts par ailleurs (ici, l'agent Google Storage Transfer).
#
# L'emplacement par défaut est volontairement placé sous /data/nextcloud, dans
# le périmètre de cet agent : le dump part ainsi hors de la machine, ce qu'une
# sauvegarde posée à côté de la base ne ferait pas.
#
# Usage :
#   ./backup-db.sh                       # sauvegarde avec les valeurs par défaut
#   BACKUP_DIR=/ailleurs ./backup-db.sh  # autre destination
#   RETENTION_DAYS=30 ./backup-db.sh     # autre rétention
#
# Codes de sortie : 0 succès, 1 erreur de configuration, 2 échec du dump.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data/nextcloud/db-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DB_CONTAINER="${DB_CONTAINER:-nextcloud-db}"
DB_NAME="${DB_NAME:-nextcloud}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
fail() { printf '[%s] ERREUR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; exit "${2:-1}"; }

command -v docker >/dev/null || fail "docker introuvable"

docker inspect "$DB_CONTAINER" >/dev/null 2>&1 \
    || fail "conteneur '$DB_CONTAINER' introuvable"
[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER")" = "true" ] \
    || fail "conteneur '$DB_CONTAINER' arrêté"

# Le mot de passe est lu dans l'environnement du conteneur et non dans .env :
# .env peut entourer la valeur de guillemets, que docker retire au démarrage.
container_env() {
    docker inspect "$DB_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | sed -n "s/^$1=//p" | head -1
}

MYSQL_PW="$(container_env MYSQL_ROOT_PASSWORD || true)"
PG_PW="$(container_env POSTGRES_PASSWORD || true)"

if   [ -n "$MYSQL_PW" ]; then ENGINE=mariadb
elif [ -n "$PG_PW" ];    then ENGINE=postgres
else fail "impossible de déterminer le moteur de base de '$DB_CONTAINER'"
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

free_mb=$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')
[ "$free_mb" -ge "$MIN_FREE_MB" ] \
    || fail "espace insuffisant sur $BACKUP_DIR : ${free_mb} Mo libres, ${MIN_FREE_MB} Mo requis"

STAMP="$(date +%Y%m%d-%H%M%S)"
TARGET="${BACKUP_DIR}/${DB_NAME}-${STAMP}.sql.gz"
TMP="${TARGET}.incomplete"

# Le dump est écrit sous un nom temporaire puis renommé : un fichier au nom
# définitif est donc toujours un dump complet, jamais une écriture en cours.
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

log "moteur détecté : $ENGINE — sauvegarde de '$DB_NAME' vers $TARGET"

# PIPESTATUS ne survit pas à la commande suivante, fût-ce une affectation :
# il est donc lu immédiatement après le pipeline, et le marqueur défini avant.
set +e
if [ "$ENGINE" = mariadb ]; then
    END_MARKER='Dump completed'
    docker exec "$DB_CONTAINER" mariadb-dump \
        -uroot -p"$MYSQL_PW" \
        --single-transaction --quick \
        --routines --triggers --events \
        "$DB_NAME" 2>/dev/null | gzip > "$TMP"
    status=${PIPESTATUS[0]}
else
    END_MARKER='PostgreSQL database dump complete'
    docker exec -e PGPASSWORD="$PG_PW" "$DB_CONTAINER" \
        pg_dump -U "${POSTGRES_USER:-nextcloud}" "$DB_NAME" 2>/dev/null | gzip > "$TMP"
    status=${PIPESTATUS[0]}
fi
set -e

[ "$status" -eq 0 ] || fail "le dump a échoué (code $status)" 2
[ -s "$TMP" ]       || fail "le dump est vide" 2

# Un dump tronqué (disque plein, conteneur tué) reste un gzip valide : seule la
# présence du marqueur de fin prouve que le moteur est allé au bout.
if ! gzip -dc "$TMP" | tail -5 | grep -q "$END_MARKER"; then
    fail "marqueur de fin absent — dump incomplet, conservé nulle part" 2
fi

chmod 600 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT

size=$(du -h "$TARGET" | cut -f1)
log "sauvegarde terminée : $TARGET ($size)"

# La rotation n'a lieu qu'après un dump validé : une série d'échecs ne peut pas
# éroder les sauvegardes déjà en place.
deleted=$(find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}-*.sql.gz" \
    -type f -mtime "+${RETENTION_DAYS}" -print -delete | wc -l)
[ "$deleted" -gt 0 ] && log "rotation : $deleted sauvegarde(s) de plus de ${RETENTION_DAYS} jours supprimée(s)"

count=$(find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}-*.sql.gz" -type f | wc -l)
total=$(du -sh "$BACKUP_DIR" | cut -f1)
log "état : $count sauvegarde(s) conservée(s), $total au total"
