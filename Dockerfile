# mesh-router-nameserver: stock PowerDNS Authoritative with this repo's config baked in,
# so a host carries only a compose file and an .env. One image, two roles (ROLE env):
# the backend's hidden primary and the public secondaries. See image/entrypoint.sh.
FROM powerdns/pdns-auth-51:5.1.5@sha256:77ff4efdbb9ec30e9309c8a1cbed6121a67fa3be25c848bbbfa756fc75bf9a27

COPY image/templates/ /etc/powerdns/templates.d/
COPY image/lua/ /etc/powerdns/lua-global/
COPY --chmod=0755 image/entrypoint.sh /usr/local/bin/nameserver-entrypoint

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/nameserver-entrypoint"]
