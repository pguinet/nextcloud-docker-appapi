#!/bin/bash
# Teste les services db (MariaDB) et redis : installation neuve et migration
# depuis les images officielles (donnees appartenant a l'uid 999).
# Usage : tests/db-redis/run.sh   (necessite Docker et 'docker login dhi.io')
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
COMPOSE=(docker compose -f compose.yml)
# extends interpole tout docker-compose.mariadb.yml : valeurs factices pour faire taire Compose
export NEXTCLOUD_DOMAIN=nc.localhost NEXTCLOUD_ADMIN_PASSWORD=x HARP_SHARED_KEY=x MYSQL_PASSWORD=x MYSQL_ROOT_PASSWORD=x
FAILURES=0
OFFICIAL_DB=mariadb:11.8
# Apostrophe volontaire : verifie l'echappement SQL de init-mariadb.sh
DB_PASSWORD="te'st"
OFFICIAL_REDIS=redis:7-alpine
ROOT=$(mktemp -d)

cleanup() {
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1
    docker rm -f db-redis-test-official-db db-redis-test-official-redis >/dev/null 2>&1
    # Les donnees appartiennent a 65532 ou 999 : suppression depuis un conteneur root
    docker run --rm --user 0 --entrypoint rm -v "$ROOT:/t" dhi.io/mariadb:11.8 -rf /t/fresh /t/migrated
    rmdir "$ROOT"
}
trap cleanup EXIT

check() {
    local name=$1 expected=$2 actual=$3
    if [ "$actual" = "$expected" ]; then
        echo "  ok   $name ($actual)"
    else
        echo "  FAIL $name : attendu $expected, obtenu $actual"
        FAILURES=$((FAILURES + 1))
    fi
}

up() {
    "${COMPOSE[@]}" up -d --wait --quiet-pull db redis >/dev/null 2>&1 \
        || { "${COMPOSE[@]}" logs; exit 1; }
}

# Client lance dans un conteneur distinct, comme Nextcloud le ferait
sql() {
    "${COMPOSE[@]}" run --rm --no-deps -T --entrypoint mariadb db \
        -h db -unextcloud -p"$DB_PASSWORD" nextcloud -Nse "$1" 2>/dev/null
}
rcli() {
    "${COMPOSE[@]}" run --rm --no-deps -T --entrypoint redis-cli redis -h redis --raw "$@" 2>/dev/null
}

wait_official_db() {
    for _ in $(seq 60); do
        docker exec db-redis-test-official-db healthcheck.sh --connect --innodb_initialized \
            >/dev/null 2>&1 && return 0
        sleep 1
    done
    docker logs db-redis-test-official-db; exit 1
}

echo "Installation neuve"
export DATA_PATH=$ROOT/fresh
../../scripts/prepare-data-dirs.sh "$DATA_PATH" || exit 1
up
check "init-mariadb.sh"           0 "$(../../scripts/init-mariadb.sh "${COMPOSE[@]}" >/dev/null 2>&1; echo $?)"
check "init-mariadb.sh rejoue"    0 "$(../../scripts/init-mariadb.sh "${COMPOSE[@]}" >/dev/null 2>&1; echo $?)"
check "image MariaDB DHI"         dhi.io/mariadb:11.8 "$(docker inspect -f '{{.Config.Image}}' db-redis-test-db)"
check "image Redis DHI"           dhi.io/redis:7 "$(docker inspect -f '{{.Config.Image}}' db-redis-test-redis)"
check "MariaDB en nonroot"        65532 "$(docker inspect -f '{{.Config.User}}' db-redis-test-db)"
check "Redis en nonroot"          65532 "$(docker inspect -f '{{.Config.User}}' db-redis-test-redis)"
check "utilisateur nextcloud"     1 "$(sql 'SELECT 1')"
check "options de mariadbd"       "ON,ROW,READ-COMMITTED,ON,0" "$(sql 'SELECT CONCAT_WS(",",
    @@log_bin, @@binlog_format, @@transaction_isolation,
    @@log_bin_trust_function_creators, @@slave_connections_needed_for_purge)')"
check "mariadb-dump (sauvegarde)" 0 "$("${COMPOSE[@]}" exec -T db mariadb-dump -uroot -ptest-root \
    --single-transaction nextcloud >/dev/null 2>&1; echo $?)"
check "Redis joignable"           PONG "$(rcli ping)"
check "Redis : --save 60 1"       "$(printf 'save\n60 1')" "$(rcli config get save)"
rcli set cle valeur >/dev/null
rcli save >/dev/null
"${COMPOSE[@]}" restart redis >/dev/null 2>&1
check "Redis : persistance"       valeur "$(rcli get cle)"
"${COMPOSE[@]}" down >/dev/null 2>&1

echo "Migration depuis les images officielles"
export DATA_PATH=$ROOT/migrated
mkdir -p "$DATA_PATH/db" "$DATA_PATH/redis"
docker run -d --name db-redis-test-official-db -v "$DATA_PATH/db:/var/lib/mysql" \
    -e MYSQL_DATABASE=nextcloud -e MYSQL_USER=nextcloud -e MYSQL_PASSWORD="$DB_PASSWORD" \
    -e MYSQL_ROOT_PASSWORD=test-root "$OFFICIAL_DB" >/dev/null || exit 1
docker run -d --name db-redis-test-official-redis -v "$DATA_PATH/redis:/data" \
    "$OFFICIAL_REDIS" >/dev/null || exit 1
wait_official_db
docker exec db-redis-test-official-db mariadb -unextcloud -p"$DB_PASSWORD" nextcloud \
    -e "CREATE TABLE oc_test (v VARCHAR(10)); INSERT INTO oc_test VALUES ('migre')"
docker exec db-redis-test-official-redis redis-cli set cle migre >/dev/null
docker exec db-redis-test-official-redis redis-cli save >/dev/null
docker stop db-redis-test-official-db db-redis-test-official-redis >/dev/null
../../scripts/prepare-data-dirs.sh "$DATA_PATH" || exit 1
up
check "MariaDB : donnees reprises" migre "$(sql 'SELECT v FROM oc_test')"
check "Redis : donnees reprises"   migre "$(rcli get cle)"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Tous les tests passent."
else
    echo "$FAILURES test(s) en echec."
    "${COMPOSE[@]}" logs | tail -30
    exit 1
fi
