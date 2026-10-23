#!/bin/sh
# Smoke test: build the image, then check what a deploy relies on —
#   the primary takes API writes as the backend makes them (catalog Producer + allow zone),
#   the secondary consumes the catalog, transfers the allow zone, answers an allowed IP
#   and not an unlisted one, and picks up a new allow record by NOTIFY.
# usage: sh test/smoke/run.sh   (Docker + compose; cleans up after itself)
set -eu
cd "$(dirname "$0")"

dc() { docker compose "$@"; }
in_client() { dc exec -T client sh -c "$1"; }
fail() { echo "FAIL: $*" >&2; dc logs primary secondary >&2 || true; exit 1; }
cleanup() { dc down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

# wait up to $1 s for command $2 to print exactly $3
wait_for() {
  i=0
  while [ "$i" -lt "$1" ]; do
    [ "$(in_client "$2" 2>/dev/null || true)" = "$3" ] && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

dc build primary
dc up -d primary client
in_client 'apk add -q curl bind-tools >/dev/null'

API='curl -sf -H "X-API-Key: smoke" -H "Content-Type: application/json"'
URL=http://172.16.54.10:8081/api/v1/servers/localhost
wait_for 30 "$API $URL >/dev/null && echo up" up || fail "primary API not up"

in_client "$API -X POST $URL/zones -d '{\"name\":\"catalog.smoke.test.invalid.\",\"kind\":\"Producer\",\"nameservers\":[]}' >/dev/null" \
  || fail "create catalog"
in_client "$API -X POST $URL/zones -d '{\"name\":\"allow.ip.smoke.test.invalid.\",\"kind\":\"Primary\",\"nameservers\":[],\"catalog\":\"catalog.smoke.test.invalid.\"}' >/dev/null" \
  || fail "create allow zone"
allow() {
  in_client "$API -X PATCH $URL/zones/allow.ip.smoke.test.invalid. -d '{\"rrsets\":[{\"name\":\"$1.allow.ip.smoke.test.invalid.\",\"type\":\"A\",\"ttl\":60,\"changetype\":\"REPLACE\",\"records\":[{\"content\":\"$2\",\"disabled\":false}]}]}'" \
    && in_client "$API -X PUT $URL/zones/allow.ip.smoke.test.invalid./notify >/dev/null"
}
allow 203-0-113-7 203.0.113.7 || fail "allow 203.0.113.7"

dc up -d secondary
Q='dig @172.16.54.11 +short +time=2 +tries=1'
# catalog cycle on the primary is 60 s; a fresh consumer transfers it at start
wait_for 90 "$Q app-203-0-113-7.ip.smoke.test" 203.0.113.7 || fail "allowed IP not answered"
echo "ok   allowed IP answered"
[ -z "$(in_client "$Q app-203-0-113-8.ip.smoke.test")" ] || fail "unlisted IP answered"
echo "ok   unlisted IP not answered"
[ "$(in_client "$Q NS ip.smoke.test | sort | tr '\n' ' '")" = "ns1.smoke.test. ns2.smoke.test. " ] || fail "ip zone NS set"
echo "ok   ip.<zone> NS set from NS_HOSTS"

allow 203-0-113-8 203.0.113.8 || fail "allow 203.0.113.8"
# NOTIFY → transfer; the packet cache (20 s) may still hold the empty answer
wait_for 30 "$Q app-203-0-113-8.ip.smoke.test" 203.0.113.8 || fail "new allow record not picked up"
echo "ok   new allow record picked up"

dc run --rm --no-deps -e ROLE= secondary >/dev/null 2>&1 && fail "missing ROLE accepted"
echo "ok   missing ROLE refused"
echo "smoke: all passed"
