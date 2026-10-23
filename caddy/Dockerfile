# Caddy avec le WAF Coraza (OWASP CRS embarque dans le module)
ARG CADDY_VERSION=2.11.7

FROM caddy:${CADDY_VERSION}-builder AS builder
ARG CORAZA_CADDY_VERSION=v2.6.2
RUN xcaddy build --with github.com/corazawaf/coraza-caddy/v2@${CORAZA_CADDY_VERSION}

FROM caddy:${CADDY_VERSION}-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Plugin CRS d'exclusions Nextcloud : evite les faux positifs WebDAV, CalDAV, editeur...
# https://github.com/coreruleset/nextcloud-rule-exclusions-plugin
ARG NC_PLUGIN_URL=https://raw.githubusercontent.com/coreruleset/nextcloud-rule-exclusions-plugin/v1.7.1/plugins
ADD --checksum=sha256:17ed8c7826c3351d8f86683a9898b88aca89311fc140f8e319d10c797d5be11a \
    ${NC_PLUGIN_URL}/nextcloud-rule-exclusions-config.conf /etc/caddy/crs-plugins/
ADD --checksum=sha256:5f398812bfec2c9d21dcad3b7898065cdfa4721cdf980bfe487e988cc4729aab \
    ${NC_PLUGIN_URL}/nextcloud-rule-exclusions-before.conf /etc/caddy/crs-plugins/
RUN chmod 644 /etc/caddy/crs-plugins/*.conf
