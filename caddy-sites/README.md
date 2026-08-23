# Sites additionnels

Ce répertoire est monté en lecture seule dans le conteneur Caddy, sous
`/etc/caddy/sites`. Tout fichier `.caddy` qui s'y trouve est importé à la fin du
`Caddyfile` principal.

Il sert à déclarer, sur un hôte donné, des sites qui n'ont pas leur place dans
ce dépôt — un autre service exposé par le même Caddy, par exemple.

Les fichiers `.caddy` sont volontairement **exclus du suivi git** (voir
`.gitignore`) : ils décrivent la réalité d'un serveur particulier, pas la stack
Nextcloud elle-même. Ils survivent donc aux `git pull`.

Exemple — `caddy-sites/mon-service.caddy` :

```caddy
mon-service.example.org {
    reverse_proxy mon-conteneur:3000

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        -Server
    }

    encode gzip zstd
}
```

Le conteneur cible doit être joignable depuis Caddy : rattachez-le au réseau
`frontend` (ou `backend`) de cette stack.

Après ajout ou modification d'un fichier :

```bash
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```
