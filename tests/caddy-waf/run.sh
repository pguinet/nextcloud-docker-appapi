#!/bin/bash
# Teste le Caddyfile de la stack : filtre IP, WAF Coraza, WebDAV, ExApps.
# Usage : tests/caddy-waf/run.sh   (necessite Docker)
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
COMPOSE=(docker compose -f compose.yml)
FAILURES=0

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1; }
trap cleanup EXIT

# curl depuis un client de test ; affiche le code HTTP
http() {
    local client=$1 addr=$2; shift 2
    "${COMPOSE[@]}" exec -T "$client" curl -sk -o /dev/null -w '%{http_code}' \
        --resolve "nc.localhost:443:${addr}" "$@"
}

check() {
    local name=$1 expected=$2 actual=$3
    if [ "$actual" = "$expected" ]; then
        echo "  ok   $name ($actual)"
    else
        echo "  FAIL $name : attendu $expected, obtenu $actual"
        FAILURES=$((FAILURES + 1))
    fi
}

"${COMPOSE[@]}" up -d --build --wait --quiet-pull >/dev/null 2>&1 || { "${COMPOSE[@]}" logs; exit 1; }
V4=198.51.100.2
V6='[2001:db8:100::2]'
URL=https://nc.localhost

# Attendre que Caddy reponde
for _ in $(seq 30); do
    [ "$(http client-allowed "$V4" "$URL/status.php")" = 200 ] && break
    sleep 1
done

echo "Filtre IP"
check "IPv4 autorisee"         200 "$(http client-allowed "$V4" "$URL/status.php")"
check "IPv4 refusee"           403 "$(http client-denied  "$V4" "$URL/status.php")"
check "IPv6 autorisee"         200 "$(http client-allowed "$V6" "$URL/status.php")"
check "IPv6 refusee"           403 "$(http client-denied  "$V6" "$URL/status.php")"
check "ExApps IP refusee"      403 "$(http client-denied  "$V4" "$URL/exapps/app/")"
check "sonde : GET status.php" 200 "$(http client-sonde   "$V4" "$URL/status.php?format=json")"
check "sonde : HEAD (IPv6)"    200 "$(http client-sonde   "$V6" -I "$URL/status.php")"
check "sonde : autre page"     403 "$(http client-sonde   "$V4" "$URL/index.php/login")"
check "sonde : POST"           403 "$(http client-sonde   "$V4" -X POST -d x=1 "$URL/status.php")"
check "conteneur backend"      200 "$(http client-backend 172.30.0.2 "$URL/status.php")"
check "autre reseau prive"     403 "$(http client-autre-prive 10.99.0.2 "$URL/status.php")"
# Depuis l'hote, la requete arrive avec l'IP de la passerelle backend
check "passerelle backend"     403 "$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve nc.localhost:443:172.30.0.2 "$URL/status.php")"

echo "Configuration de prod"
# Le Caddyfile doit aussi se charger avec la vraie liste UptimeRobot
check "Caddyfile + vraie liste" 0 "$(docker run --rm --entrypoint caddy -e NEXTCLOUD_DOMAIN=nc.localhost \
    -e NEXTCLOUD_BACKEND_SUBNET=172.18.0.0/16 -e NEXTCLOUD_BACKEND_GATEWAY=172.18.0.1 \
    -v "$PWD/../../Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$PWD/../../caddy/coraza:/etc/caddy/coraza:ro" \
    -v "$PWD/../../caddy/uptimerobot-ips.caddy:/etc/caddy/uptimerobot-ips.caddy:ro" \
    nextcloud-caddy-waf validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; echo $?)"

echo "WAF"
check "injection SQL"          403 "$(http client-allowed "$V4" "$URL/index.php?id=1%27%20OR%20%271%27=%271")"
check "XSS"                    403 "$(http client-allowed "$V4" "$URL/index.php?q=%3Cscript%3Ealert(1)%3C/script%3E")"
check "traversee"              403 "$(http client-allowed "$V4" "$URL/index.php?file=../../../../etc/passwd")"
check "injection de commande"  403 "$(http client-allowed "$V4" "$URL/index.php?cmd=;cat%20/etc/passwd")"
check "scanner (UA nikto)"     403 "$(http client-allowed "$V4" -A 'Mozilla/5.00 (Nikto/2.1.6)' "$URL/")"
check "SQL dans un formulaire" 403 "$(http client-allowed "$V4" -X POST \
    -d "user=admin' UNION SELECT password FROM oc_users--" "$URL/index.php/login")"

echo "Trafic Nextcloud legitime"
check "page de login"          200 "$(http client-allowed "$V4" "$URL/index.php/login")"
check "OCS JSON"               200 "$(http client-allowed "$V4" -X POST -H 'OCS-APIRequest: true' \
    -H 'Content-Type: application/json' -d '{"shareType":0,"path":"/Documents"}' \
    "$URL/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json")"
check "PROPFIND WebDAV"        200 "$(http client-allowed "$V4" -X PROPFIND -H 'Depth: 1' \
    -H 'Content-Type: application/xml' \
    -d '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/></d:prop></d:propfind>' \
    "$URL/remote.php/dav/files/alice/")"
check "REPORT CalDAV"          200 "$(http client-allowed "$V4" -X REPORT -H 'Depth: 1' \
    -H 'Content-Type: application/xml' \
    -d '<?xml version="1.0"?><c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></c:calendar-query>' \
    "$URL/remote.php/dav/calendars/alice/personal/")"
check "PUT fichier suspect"    200 "$(http client-allowed "$V4" -X PUT \
    --data-binary "SELECT * FROM oc_users UNION SELECT 1; <script>alert(1)</script> ../../etc/passwd" \
    "$URL/remote.php/dav/files/alice/notes.sql")"
check "PUT 50 Mo"              200 "$("${COMPOSE[@]}" exec -T client-allowed sh -c \
    "head -c 52428800 /dev/urandom > /tmp/big && curl -sk -o /dev/null -w '%{http_code}' \
     --resolve nc.localhost:443:$V4 -X PUT -T /tmp/big $URL/remote.php/dav/uploads/alice/web-file-upload-1/00001")"
check "redirection CalDAV"     301 "$(http client-allowed "$V4" "$URL/.well-known/caldav")"
check "fichier sensible"       404 "$(http client-allowed "$V4" "$URL/occ")"
check "ExApps hors WAF"        200 "$(http client-allowed "$V4" "$URL/exapps/app/?id=1%27%20OR%20%271%27=%271")"

echo "Image"
CADDY_ID=$("${COMPOSE[@]}" ps -q caddy)
check "Caddy en nonroot"       65532 "$(docker inspect -f '{{.Config.User}}' "$CADDY_ID")"
check "module Coraza"          1 "$("${COMPOSE[@]}" exec -T caddy caddy list-modules 2>/dev/null | grep -c '^http.handlers.waf$')"
# Le log d'acces est ecrit dans le volume caddy_data : verifie les droits de /data/logs
check "log d'acces ecrit"      0 "$("${COMPOSE[@]}" cp caddy:/data/logs/nextcloud.log - 2>/dev/null \
    | tar -xO | grep status.php >/dev/null; echo $?)"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Tous les tests passent."
else
    echo "$FAILURES test(s) en echec."
    "${COMPOSE[@]}" logs caddy | grep -i -E 'coraza|error' | tail -20
    exit 1
fi
