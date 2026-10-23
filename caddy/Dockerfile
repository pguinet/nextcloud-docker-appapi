# Caddy avec le WAF Coraza (OWASP CRS embarque dans le module)
ARG CADDY_VERSION=2.11.7

FROM caddy:${CADDY_VERSION}-builder AS builder
ARG CORAZA_CADDY_VERSION=v2.6.2
RUN xcaddy build --with github.com/corazawaf/coraza-caddy/v2@${CORAZA_CADDY_VERSION}

# Plugin CRS d'exclusions Nextcloud : evite les faux positifs WebDAV, CalDAV, editeur...
# https://github.com/coreruleset/nextcloud-rule-exclusions-plugin
# Telecharge ici : l'image finale n'a pas de shell pour un RUN.
ARG NC_PLUGIN_URL=https://raw.githubusercontent.com/coreruleset/nextcloud-rule-exclusions-plugin/v1.7.1/plugins
ADD --chmod=644 --checksum=sha256:17ed8c7826c3351d8f86683a9898b88aca89311fc140f8e319d10c797d5be11a \
    ${NC_PLUGIN_URL}/nextcloud-rule-exclusions-config.conf /crs-plugins/
ADD --chmod=644 --checksum=sha256:5f398812bfec2c9d21dcad3b7898065cdfa4721cdf980bfe487e988cc4729aab \
    ${NC_PLUGIN_URL}/nextcloud-rule-exclusions-before.conf /crs-plugins/
RUN mkdir -p /data/logs

# Docker Hardened Image : nonroot (uid 65532), sans shell ni gestionnaire de paquets
FROM dhi.io/caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/local/bin/caddy
COPY --from=builder /crs-plugins/ /etc/caddy/crs-plugins/
# /data appartient a root dans l'image : sans ce repertoire, un volume caddy_data neuf
# n'aurait pas de logs/ inscriptible pour le log d'acces (Caddyfile : /data/logs)
COPY --from=builder --chown=65532:65532 /data/logs /data/logs
