#!/bin/bash
# ===========================================
# Crée la base et l'utilisateur Nextcloud dans MariaDB
# ===========================================
# Contrairement à l'image officielle, l'image Docker Hardened Images (dhi.io)
# de MariaDB n'initialise que le compte root : elle ignore MYSQL_DATABASE,
# MYSQL_USER et MYSQL_PASSWORD. Ce script les crée à partir des variables
# d'environnement du conteneur db, avant le premier démarrage de Nextcloud.
#
# Usage : scripts/init-mariadb.sh [commande compose...]   (défaut : docker compose)
# Idempotent : sans effet sur une base existante.

set -euo pipefail

[ $# -eq 0 ] && set -- docker compose

"$@" exec -T db bash -s <<'EOS'
set -euo pipefail
sql_quote() { local v=${1//\\/\\\\}; printf "'%s'" "${v//\'/\'\'}"; }
db=${MYSQL_DATABASE//\`/\`\`}
MYSQL_PWD=$MYSQL_ROOT_PASSWORD mariadb --protocol=socket -uroot <<EOSQL
CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS $(sql_quote "$MYSQL_USER")@'%' IDENTIFIED BY $(sql_quote "$MYSQL_PASSWORD");
GRANT ALL PRIVILEGES ON \`$db\`.* TO $(sql_quote "$MYSQL_USER")@'%';
EOSQL
EOS
