#!/bin/bash
# Teste scripts/generate-env.sh : pour chaque variante, le .env genere doit fournir
# toutes les variables du compose et conserver les valeurs saisies a l'identique
# (espaces, $, guillemets), lu par Compose comme par bash.
# Usage : tests/install/run.sh   (necessite Docker Compose et jq)
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
GEN=scripts/generate-env.sh
FAILURES=0
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT

check() {
    local name=$1 expected=$2 actual=$3
    if [ "$actual" = "$expected" ]; then
        echo "  ok   $name ($actual)"
    else
        echo "  FAIL $name : attendu $expected, obtenu $actual"
        FAILURES=$((FAILURES + 1))
    fi
}

DOMAIN=nc.example.org
# shellcheck disable=SC2016  # $HOME litteral : verifie qu'il n'est pas interprete
ADMIN_PASS='p@ss word $HOME "x"'
IPS='198.51.100.7 2001:db8:1234:5600::/56'

for variant in mariadb postgres; do
    echo "Variante $variant"
    env_file=$TMP/$variant.env
    printf '%s\n' "$DOMAIN" "" "$ADMIN_PASS" "$IPS" | $GEN "$variant" "$env_file" 2>/dev/null
    check "generation"            0 "$?"
    check "droits du fichier"     600 "$(stat -c %a "$env_file")"

    compose=(docker compose -f "docker-compose.$variant.yml" --env-file "$env_file")
    check "aucune variable manquante" 0 "$("${compose[@]}" config -q 2>&1 | grep -c 'variable is not set')"
    config=$("${compose[@]}" config --format json 2>/dev/null)
    # config echappe $ en $$ dans sa sortie ; le conteneur recoit bien un seul $
    get() { jq -r --arg s "$1" --arg v "$2" '.services[$s].environment[$v] | gsub("\\$\\$"; "$")' <<<"$config"; }
    check "domaine"               "$DOMAIN" "$(get caddy NEXTCLOUD_DOMAIN)"
    check "IP autorisees"         "$IPS" "$(get caddy NEXTCLOUD_ALLOWED_IPS)"
    check "admin par defaut"      admin "$(get nextcloud NEXTCLOUD_ADMIN_USER)"
    check "mot de passe admin"    "$ADMIN_PASS" "$(get nextcloud NEXTCLOUD_ADMIN_PASSWORD)"
    check "cle HaRP (64 hex)"     1 "$(get appapi-harp HP_SHARED_KEY | grep -cE '^[0-9a-f]{64}$')"
    if [ "$variant" = mariadb ]; then
        db_pass=$(get db MYSQL_PASSWORD)
        check "mot de passe base"     32 "${#db_pass}"
        check "meme mot de passe NC"  "$db_pass" "$(get nextcloud MYSQL_PASSWORD)"
        check "mot de passe root"     32 "$(get db MYSQL_ROOT_PASSWORD | tr -d '\n' | wc -c)"
    else
        db_pass=$(get db POSTGRES_PASSWORD)
        check "mot de passe base"     32 "${#db_pass}"
    fi
    # shellcheck disable=SC1090  # le .env genere par le test
    check "lu par bash"           "$ADMIN_PASS|$IPS" "$(set -a; . "$env_file"; echo "$NEXTCLOUD_ADMIN_PASSWORD|$NEXTCLOUD_ALLOWED_IPS")"
done

echo "Refus"
printf '%s\n' "$DOMAIN" "" "x" "" | $GEN mariadb "$TMP/mariadb.env" >/dev/null 2>&1
check "pas d'ecrasement"      1 "$?"
printf '%s\n' "$DOMAIN" "" "l'apostrophe" "" | $GEN mariadb "$TMP/quote.env" >/dev/null 2>&1
check "apostrophe refusee"    "1 absent" "$? $([ -e "$TMP/quote.env" ] && echo present || echo absent)"
printf '%s\n' "" | $GEN mariadb "$TMP/vide.env" >/dev/null 2>&1
check "domaine obligatoire"   1 "$?"
$GEN mysql "$TMP/x.env" </dev/null >/dev/null 2>&1
check "variante inconnue"     2 "$?"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Tous les tests passent."
else
    echo "$FAILURES test(s) en echec."
    exit 1
fi
