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
#   COMPRESSOR=gzip ./backup-db.sh       # xz (défaut), zstd ou gzip
#   EXCLUDE_TABLES= ./backup-db.sh       # dump intégral, sans exclusion
#
# Restauration : après réimport, régénérer les données exclues avec
#   docker compose exec -u www-data nextcloud php occ memories:places-setup
#
# Codes de sortie : 0 succès, 1 erreur de configuration, 2 échec du dump.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data/nextcloud/db-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-35}"
DB_CONTAINER="${DB_CONTAINER:-nextcloud-db}"
DB_NAME="${DB_NAME:-nextcloud}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"
# xz gagne ~40 % sur gzip pour un dump SQL, ce qui compte quand la destination
# est facturée au volume. Repasser à gzip si le temps CPU pose problème.
COMPRESSOR="${COMPRESSOR:-xz}"

# Tables dont les DONNÉES sont exclues du dump — leur structure, elle, est
# conservée, si bien que la restauration les recrée vides et que l'application
# ne trouve pas une table manquante.
#
# N'y placer que des données reconstructibles sans perte et sans référence
# depuis le reste du schéma. Les tables planet de Memories sont des données
# OpenStreetMap statiques, régénérées par `occ memories:places-setup` ; elles
# pèsent à elles seules plus des trois quarts du dump.
#
# À l'inverse, oc_filecache n'a rien à faire ici : les partages référencent les
# fileid, qu'un rescan réattribuerait — les partages seraient rompus.
EXCLUDE_TABLES="${EXCLUDE_TABLES-memories_planet_geometry oc_memories_planet}"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
# Lecture indifferente au compresseur, pour verifier aussi les anciens dumps.
decompress() {
    case "$1" in
        *.xz|*.xz.incomplete)   xz -dc  "$1" ;;
        *.zst|*.zst.incomplete) zstd -dc "$1" ;;
        *)                      gzip -dc "$1" ;;
    esac
}
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

case "$COMPRESSOR" in
    xz)   COMPRESS_CMD=(xz -6 -T0 -c);  EXT=xz  ;;
    zstd) COMPRESS_CMD=(zstd -19 -T0 -q -c); EXT=zst ;;
    gzip) COMPRESS_CMD=(gzip);          EXT=gz  ;;
    *)    fail "compresseur inconnu : $COMPRESSOR (xz, zstd ou gzip)" ;;
esac
command -v "${COMPRESS_CMD[0]}" >/dev/null || fail "${COMPRESS_CMD[0]} introuvable"

STAMP="$(date +%Y%m%d-%H%M%S)"
TARGET="${BACKUP_DIR}/${DB_NAME}-${STAMP}.sql.${EXT}"
TMP="${TARGET}.incomplete"

# Le dump est écrit sous un nom temporaire puis renommé : un fichier au nom
# définitif est donc toujours un dump complet, jamais une écriture en cours.
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

log "moteur détecté : $ENGINE, compression $COMPRESSOR — sauvegarde de '$DB_NAME' vers $TARGET"
if [ "$ENGINE" = mariadb ] && [ -n "$EXCLUDE_TABLES" ]; then
    log "données exclues (structure conservée) : $EXCLUDE_TABLES"
fi

# PIPESTATUS ne survit pas à la commande suivante, fût-ce une affectation :
# il est donc lu immédiatement après le pipeline, et le marqueur défini avant.
set +e
if [ "$ENGINE" = mariadb ]; then
    END_MARKER='Dump completed'
    ignore_args=()
    for t in $EXCLUDE_TABLES; do ignore_args+=("--ignore-table=${DB_NAME}.${t}"); done

    if [ ${#ignore_args[@]} -eq 0 ]; then
        docker exec "$DB_CONTAINER" mariadb-dump \
            -uroot -p"$MYSQL_PW" \
            --single-transaction --quick \
            --routines --triggers --events \
            "$DB_NAME" 2>/dev/null | "${COMPRESS_CMD[@]}" > "$TMP"
        status=${PIPESTATUS[0]}
    else
        # Deux passes : le schéma complet, puis les données sans les tables
        # exclues. Un seul --ignore-table ferait disparaître aussi la structure.
        {
            docker exec "$DB_CONTAINER" mariadb-dump -uroot -p"$MYSQL_PW" \
                --no-data --routines --triggers --events "$DB_NAME" 2>/dev/null || exit 1
            docker exec "$DB_CONTAINER" mariadb-dump -uroot -p"$MYSQL_PW" \
                --no-create-info --single-transaction --quick \
                "${ignore_args[@]}" "$DB_NAME" 2>/dev/null || exit 1
        } | "${COMPRESS_CMD[@]}" > "$TMP"
        status=${PIPESTATUS[0]}
    fi
else
    END_MARKER='PostgreSQL database dump complete'
    docker exec -e PGPASSWORD="$PG_PW" "$DB_CONTAINER" \
        pg_dump -U "${POSTGRES_USER:-nextcloud}" "$DB_NAME" 2>/dev/null | "${COMPRESS_CMD[@]}" > "$TMP"
    status=${PIPESTATUS[0]}
fi
set -e

[ "$status" -eq 0 ] || fail "le dump a échoué (code $status)" 2
[ -s "$TMP" ]       || fail "le dump est vide" 2

# Un dump tronqué (disque plein, conteneur tué) reste une archive parfaitement
# valide : seule la présence du marqueur de fin prouve que le moteur est allé
# au bout. Un test d'intégrité de la compression ne suffit donc pas.
if ! decompress "$TMP" | tail -5 | grep -q "$END_MARKER"; then
    fail "marqueur de fin absent — dump incomplet, conservé nulle part" 2
fi

chmod 600 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT

size=$(du -h "$TARGET" | cut -f1)
log "sauvegarde terminée : $TARGET ($size)"

# La rotation n'a lieu qu'après un dump validé : une série d'échecs ne peut pas
# éroder les sauvegardes déjà en place.
deleted=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "${DB_NAME}-*.sql.gz" \
    -o -name "${DB_NAME}-*.sql.xz" -o -name "${DB_NAME}-*.sql.zst" \) \
    -type f -mtime "+${RETENTION_DAYS}" -print -delete | wc -l)
if [ "$deleted" -gt 0 ]; then
    log "rotation : $deleted sauvegarde(s) de plus de ${RETENTION_DAYS} jours supprimée(s)"
fi

count=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "${DB_NAME}-*.sql.gz" \
    -o -name "${DB_NAME}-*.sql.xz" -o -name "${DB_NAME}-*.sql.zst" \) -type f | wc -l)
total=$(du -sh "$BACKUP_DIR" | cut -f1)
log "état : $count sauvegarde(s) conservée(s), $total au total"
