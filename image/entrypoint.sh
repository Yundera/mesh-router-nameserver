#!/bin/sh
# mesh-router-nameserver entrypoint. ROLE picks the PowerDNS config baked into the image,
# then the stock startup renders it (TEMPLATE_FILES) and runs pdns_server.
#   ROLE=primary    hidden primary, written by the backend over the API
#   ROLE=secondary  public nameserver: catalog consumer of the primary + local ip.<zone>
set -eu

need() {
  for v in "$@"; do
    eval "[ -n \"\${$v:-}\" ]" || { echo "nameserver: $v is required for ROLE=$ROLE" >&2; exit 1; }
  done
}
fqdn() { echo "${1%.}."; }

case "${ROLE:-}" in
primary)
  need PDNS_AUTH_API_KEY DNS_SOA_NS DNS_SECONDARY_IPS
  ;;
secondary)
  need IP_ZONE NS_HOSTS SOA_RNAME CATALOG_ZONE PRIMARY_IP
  PRIMARY_PORT=${PRIMARY_PORT:-53}

  # Local zones in the SQLite database. Idempotent: ip.<zone> is rebuilt from env on
  # every start; the catalog consumer is created once (its member zones then come and
  # go with the primary's catalog).
  IPZ=$(fqdn "$IP_ZONE")
  CAT=$(fqdn "$CATALOG_ZONE")
  FIRST_NS=$(fqdn "$(echo "$NS_HOSTS" | cut -d, -f1)")

  # names as listed, without the trailing dot
  zones=$(pdnsutil zone list-all | sed "s/\.$//")

  # not from the list: zone list-all omits a consumer that never got its first transfer
  # (no SOA yet), and recreating it fails, so a restart before that transfer crash-looped
  if ! pdnsutil zone show "$CAT" >/dev/null 2>&1; then
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

  # Catch-up after a restart: PowerDNS does not re-check its secondary zones at start, so
  # one that was down while the primary changed (it missed the NOTIFY) would serve the old
  # copy until its SOA refresh (900 s). Once the server answers, ask the primary for each
  # secondary zone and the catalog (2026-11-03 outage drill, #948). Background: the server
  # is exec'd below; tini reaps this subshell.
  (
    for _ in $(seq 1 60); do
      pdns_control rping >/dev/null 2>&1 && break
      sleep 1
    done
    n=0
    for z in "$CAT" $(pdnsutil zone list-all secondary 2>/dev/null); do
      pdns_control retrieve "$z" >/dev/null 2>&1 && n=$((n + 1))
    done
    echo "nameserver: catch-up after start, asked the primary for $n zone(s)"
  ) &
  ;;
*)
  echo "nameserver: set ROLE=primary or ROLE=secondary" >&2
  exit 1
  ;;
esac

# the role's template first; TEMPLATE_FILES may add operator templates mounted in templates.d
TEMPLATE_FILES="$ROLE${TEMPLATE_FILES:+,$TEMPLATE_FILES}"
export TEMPLATE_FILES
exec /usr/local/sbin/pdns_server-startup "$@"
