#!/usr/bin/env bash
#
# Régénère caddy/uptimerobot-ips.caddy à partir de la liste officielle des
# adresses des sondes UptimeRobot (https://uptimerobot.com/help/locations/).
#
# Le filtre IP de Caddy laisse ces adresses interroger /status.php, et rien
# d'autre. La liste évolue : relancer ce script si des sondes sont refusées,
# puis recharger Caddy :
#   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
#
# Codes de sortie : 0 succès, 1 liste invalide ou téléchargement en échec.

set -euo pipefail

URL="${UPTIMEROBOT_IPS_URL:-https://cdn.uptimerobot.com/api/IPv4andIPv6.txt}"
# En dessous, la liste est sûrement tronquée ou n'est pas celle attendue
MIN_ENTRIES=50

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${OUTPUT:-$(dirname "$SCRIPT_DIR")/caddy/uptimerobot-ips.caddy}"

raw="$(curl -fsS --max-time 30 "$URL")" || {
    echo "Téléchargement impossible : $URL" >&2
    exit 1
}

# Une adresse IPv4 ou IPv6 par ligne, CIDR facultatif ; le reste est rejeté
ips="$(printf '%s\n' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' | sort -u)"
invalid="$(printf '%s\n' "$ips" \
    | grep -Ev '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^[0-9a-fA-F:]+(/[0-9]{1,3})?$' || true)"
if [ -n "$invalid" ]; then
    echo "Entrées invalides dans la liste :" >&2
    printf '%s\n' "$invalid" >&2
    exit 1
fi

count="$(printf '%s\n' "$ips" | wc -l)"
if [ "$count" -lt "$MIN_ENTRIES" ]; then
    echo "Seulement $count adresses (minimum attendu : $MIN_ENTRIES)" >&2
    exit 1
fi

tmp="$(mktemp "${OUTPUT}.XXXXXX")"
{
    echo "# Adresses des sondes UptimeRobot, importees par le Caddyfile."
    echo "# Genere par scripts/update-uptimerobot-ips.sh : ne pas modifier a la main."
    echo "# Source : $URL"
    printf '%s\n' "$ips" | sed 's/^/remote_ip /'
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$OUTPUT"

echo "$count adresses écrites dans $OUTPUT"
