# Prod rollout — tunnel firewall + routed tunnel (2026-10-27)

> Runbook for **yundera-prod** (`ssh ubuntu@151.115.97.163`), run by hand. Staging
> (nasselle) has run the same images since 2026-10-27; design and staging record in
> [`phase-1.1-gateway-tls.md`](phase-1.1-gateway-tls.md) §5.

| Component | From (2026-10-26 read) | To |
|---|---|---|
| `mesh-router-tunnel` (provider) | 1.3.0 (to confirm in step 0) | **1.4.0**: firewall, boxes reach nothing through the tunnel |
| `mesh-router-backend` | 2.0.36 | **2.0.38**: `tunnelIp` route field; also 2.0.37 (catalog serial fix) |
| `mesh-router-gateway` | 1.3.1 | **1.4.0**: routed tunnel; also 1.3.2 (no `DEFAULT_BACKEND` default) |

**What changes for users today: nothing visible.** Prod boxes follow the template
`stable` channel, which still pins tunnel 1.3.0: no box sends a `tunnelIp`, so the
gateway keeps the provider's HTTP path for every tunnel route. The routed path engages
box by box once tunnel 1.4.0 reaches them (step 4 tests it on holyhorse; the fleet waits
for a `stable` promotion, a separate decision).

What it closes: any box owner reaching `mesh-internal` through the tunnel (the backend's
Redis at `172.30.0.2:6379` has no password: routes of every user, readable and
writable). Confirmed exploitable on staging.

Order: tunnel, backend, gateway. **Restart the gateway only after the backend answers**
(2026-10-26: a gateway restarted in the same second as the backend cached failed
resolves for 3-4 min). Backups are suffixed `.bak-2026-10-27-p11`.

Paths below assume prod's layout under `/workspace/config/mesh-router-nsl/`; step 0
confirms them. Several prod compose files are CRLF: use the `sed` forms given (they never
anchor on line ends) or an editor.

## 0. Preflight (read-only)

```bash
cd /workspace/config/mesh-router-nsl
# images and the env/volume/network lines this runbook touches
grep -n "image:\|ipv4_address\|TUNNEL_\|PROVIDER_ROUTE\|DEFAULT_BACKEND\|cap_add\|NET_ADMIN\|wireguard\|entrypoint" \
  tunnel/docker-compose.yml backend/docker-compose.yml gateway/docker-compose.yml
docker version --format '{{.Server.Version}}'
T=$(docker ps --format '{{.Names}}' | grep -i tunnel | head -1); echo "$T"
docker exec $T sh -c 'iptables -S FORWARD; wg show wg0 | grep -c peer'
# baseline on holyhorse (test PCS): direct, gateway, tunnel
for f in direct gateway tunnel; do
  curl -s -o /dev/null -w "$f %{http_code} " -D - -H "X-Mesh-Force: $f" -H "X-Mesh-Trace: 1" \
    https://mesh-console-holyhorse.nsl.sh/ | grep -i x-mesh-route
done
```

Go only if:

- the gateway has a **fixed** `ipv4_address` on `mesh-internal` (expected `172.30.0.4`)
  and so does the tunnel (expected `172.30.0.5`). If the gateway's address is dynamic,
  add `ipv4_address: 172.30.0.4` to it first (or use the network CIDR in
  `TUNNEL_FORWARD_FROM`, which also lets the backend and Redis containers forward into
  the tunnel: acceptable, looser);
- the tunnel mounts its `wg0.conf` (expected `./wg/wg0.conf`), so the backup below covers it;
- `DEFAULT_BACKEND` is either set explicitly on the gateway (behaviour unchanged) or you
  accept that unknown names get a 404 instead of a 502;
- the three holyhorse traces answer (note the codes: they are the comparison for
  every later check).

If the live iptables mitigation was applied earlier, `FORWARD` shows policy `DROP`;
that is fine, 1.4.0 replaces it.

## 1. Tunnel provider → 1.4.0

```bash
cd /workspace/config/mesh-router-nsl/tunnel
cp docker-compose.yml docker-compose.yml.bak-2026-10-27-p11
cp wg/wg0.conf wg/wg0.conf.bak-2026-10-27-p11
sed -i 's#mesh-router-tunnel:1\.[0-9.]*#mesh-router-tunnel:1.4.0#' docker-compose.yml
# the gateway's mesh-internal address, after the PROVIDER_ROUTE_PORT line
sed -i '/PROVIDER_ROUTE_PORT/a\      - TUNNEL_FORWARD_FROM=172.30.0.4' docker-compose.yml
diff docker-compose.yml.bak-2026-10-27-p11 docker-compose.yml
docker compose pull -q && docker compose up -d
```

(If the environment is a map rather than a list, add `TUNNEL_FORWARD_FROM: "172.30.0.4"`
by hand instead of the second `sed`.)

Check:

```bash
docker compose logs --tail 60 | grep -i "firewall\|hook\|error"
#   Removed PostUp/PostDown hooks from the existing WireGuard configuration
#   [firewall] applied: box traffic blocked, forward to wg0 tcp/443 from 172.30.0.4
T=$(docker ps --format '{{.Names}}' | grep -i tunnel | head -1)
docker exec $T sh -c 'iptables -S MESH_FWD; iptables -S FORWARD | head -1; grep -c PostUp /etc/wireguard/wg0.conf; wg show wg0 | grep -c peer'
#   MESH_FWD rules, -P FORWARD DROP, 0, same peer count as step 0
curl -s -o /dev/null -w "%{http_code} " -D - -H "X-Mesh-Force: tunnel" -H "X-Mesh-Trace: 1" \
  https://mesh-console-holyhorse.nsl.sh/ | grep -i x-mesh-route
#   same code as step 0, route ...,gateway,tunnel,pcs
```

NAT boxes lose their tunnel for the few seconds of the restart; their WireGuard peers come
back from the persisted config (staging: 25/25 immediately).

Rollback: `cp docker-compose.yml.bak-2026-10-27-p11 docker-compose.yml && cp wg/wg0.conf.bak-2026-10-27-p11 wg/wg0.conf && docker compose up -d`
(this reopens the hole; re-apply the live iptables mitigation after).

## 2. Backend → 2.0.38

```bash
cd /workspace/config/mesh-router-nsl/backend
cp docker-compose.yml docker-compose.yml.bak-2026-10-27-p11
sed -i 's#mesh-router-backend:2\.0\.[0-9]*#mesh-router-backend:2.0.38#' docker-compose.yml
diff docker-compose.yml.bak-2026-10-27-p11 docker-compose.yml
docker compose pull -q && docker compose up -d
```

Check (wait for 200 before step 3):

```bash
curl -s -o /dev/null -w "resolve %{http_code}\n" https://nsl.sh/router/api/resolve/v2/holyhorse
curl -s -o /dev/null -w "dns health %{http_code}\n" https://nsl.sh/router/api/dns/health
docker compose logs --tail 80 | grep -i "catalog\|SOA-EDIT\|error"
```

2.0.37 switches the producer catalog's `SOA-EDIT-API` from `EPOCH` to none on start
(logged); that is expected. Agent routes may be missing from `/resolve` for up to one
agent cycle (5 min) only if the backend's Redis route sources were lost, which 2.0.28+
prevents.

Rollback: restore the compose backup, `docker compose up -d`.

## 3. Gateway → 1.4.0 (after step 2 answers)

```bash
cd /workspace/config/mesh-router-nsl/gateway
cp docker-compose.yml docker-compose.yml.bak-2026-10-27-p11
sed -i 's#mesh-router-gateway:1\.[0-9.]*#mesh-router-gateway:1.4.0#' docker-compose.yml
```

Then by hand in the gateway service (YAML structure, so an editor is safer than `sed`):

```yaml
    cap_add:
      - NET_ADMIN            # own network namespace only: one route to the tunnel subnet
    environment:
      # ...existing entries...
      - TUNNEL_SUBNET=10.78.0.0/16
      - TUNNEL_VIA=172.30.0.5   # the tunnel container's mesh-internal address
```

If a temporary `./entrypoint.sh:/entrypoint.sh` bind mount exists, remove it: 1.4.0
contains that change.

```bash
diff docker-compose.yml.bak-2026-10-27-p11 docker-compose.yml
docker compose pull -q && docker compose up -d
```

Check:

```bash
docker compose logs --tail 40 | grep -i "Routed tunnel\|WARNING\|error"
#   Routed tunnel: 10.78.0.0/16 via 172.30.0.5
G=$(docker ps --format '{{.Names}}' | grep -i gateway | head -1)
docker exec $G ip route | grep 10.78
for f in direct gateway tunnel; do
  curl -s -o /dev/null -w "$f %{http_code} " -D - -H "X-Mesh-Force: $f" -H "X-Mesh-Trace: 1" \
    https://mesh-console-holyhorse.nsl.sh/ | grep -i x-mesh-route
done
#   same codes as step 0; tunnel still ...,gateway,tunnel,pcs (holyhorse has no tunnelIp yet)
```

Rollback: restore the compose backup, `docker compose up -d`.

## 4. Routed path on one box (holyhorse, pre-authorized test PCS)

Only once 1-3 hold. Puts holyhorse's tunnel on 1.4.0 by hand; its next self-check
rewrites the compose from its channel (main already pins 1.4.0; stable puts 1.3.0 back,
which only returns it to the legacy path).

```bash
ssh admin@161.97.177.252 'cd /DATA/AppData/mesh && sudo cp docker-compose.yml docker-compose.yml.bak-2026-10-27-p11 \
  && sudo sed -i "s#mesh-router-tunnel:1\.[0-9.]*#mesh-router-tunnel:1.4.0#" docker-compose.yml \
  && sudo docker compose up -d mesh-router-tunnel'
# after ≤ 60 s (gateway route cache):
curl -s -o /dev/null -w "%{http_code} " -D - -H "X-Mesh-Force: tunnel" -H "X-Mesh-Trace: 1" \
  https://mesh-console-holyhorse.nsl.sh/ | grep -i x-mesh-route
#   ...,gateway,tunnel-routed,pcs
```

If it answers 502 instead: the host's Docker filters the routed frames (staging, Docker
28.3.2, did not). Revert holyhorse's compose; the rest of the rollout stays valid, the
routed path then needs the host question reopened.

Security re-test from holyhorse (expects `redis_nc_exit=1`):

```bash
ssh admin@161.97.177.252 'sudo docker exec mesh-router-tunnel sh -c "
I=\$(wg show interfaces | tr \" \" \"\n\" | head -1); P=\$(wg show \$I peers | head -1)
wg set \$I peer \$P allowed-ips 10.78.0.1/32,172.30.0.2/32; ip route add 172.30.0.2/32 dev \$I
(printf \"PING\r\n\"; sleep 2) | nc -w 3 172.30.0.2 6379; echo redis_nc_exit=\$?
ip route del 172.30.0.2/32 dev \$I; wg set \$I peer \$P allowed-ips 10.78.0.1/32"'
```

## Not in this rollout

- Template `stable` promotion (tunnel 1.4.0 for the fleet): `main` also carries other
  changes; separate decision.
- Redis `requirepass` on the backend (defence in depth; needs `REDIS_URL` updated too).
- Gateway image logs `vdev`: the CI workflow does not pass `BUILD_VERSION` (cosmetic).
