#!/bin/sh
# Start hook: make the local zones in the SQLite database, then start PowerDNS.
# Idempotent: ip.<zone> is rebuilt from env on every start; the catalog consumer is
# created once (its member zones then come and go with the primary's catalog).
set -eu

fqdn() { echo "${1%.}."; }
IPZ=$(fqdn "$IP_ZONE")
CAT=$(fqdn "$CATALOG_ZONE")
FIRST_NS=$(fqdn "$(echo "$NS_HOSTS" | cut -d, -f1)")

# names as listed, without the trailing dot
zones=$(pdnsutil zone list-all | sed "s/\.$//")

if ! echo "$zones" | grep -qxF "${CAT%.}"; then
  pdnsutil zone create-secondary "$CAT" "$PRIMARY_IP:$PRIMARY_PORT"
  pdnsutil zone set-kind "$CAT" consumer
fi

if echo "$zones" | grep -qxF "${IPZ%.}"; then
  pdnsutil zone delete "$IPZ"
fi
pdnsutil zone create "$IPZ"
pdnsutil rrset replace "$IPZ" "$IPZ" SOA 300 "$FIRST_NS $(fqdn "$SOA_RNAME") $(date +%s) 900 900 1209600 30"
ns_records=""
for ns in $(echo "$NS_HOSTS" | tr , ' '); do
  ns_records="$ns_records $(fqdn "$ns")"
done
# shellcheck disable=SC2086
pdnsutil rrset replace "$IPZ" "$IPZ" NS 300 $ns_records
pdnsutil rrset replace "$IPZ" "*.$IPZ" LUA 300 'A ";return ipname4()"' 'AAAA ";return ipname6()"'

exec /usr/local/sbin/pdns_server-startup "$@"
