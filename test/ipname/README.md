# ip.<zone> parity test

> Since 2026-10-23 the include only answers IPs listed in `allow.<ip-zone>.invalid`
> (architecture §10.2). To rerun the parity test, also create that zone on the test
> server and allow every IP sslip.io returns for the corpus (key = dashed IPv4, or
> the 32-digit expanded IPv6). Gated run, 2026-10-23: 189 IPs allowed, every IP
> answer identical (577 same; the 4 differences are the 2 below plus the test
> server's own NS/SOA names). Harness: `/d/workspace/tmp-claude/pdns-ipname/`.

Compares the PowerDNS LUA wildcard (`deploy/secondary/lua/ipname.lua`) with the
sslip.io server that serves `ip.<zone>` today, answer for answer, over `corpus.txt`
(45 hand-picked names + 536 generated ones; zone `ip.test`).

Result on 2026-10-23, PowerDNS 5.1.5 vs `cunnie/sslip.io-dns-server@sha256:0c5149…`:
**579 same, 2 different**, both expected: sslip.io answers `MX 0 <name>` for every
name, and serves its own NS glue (`ns1-ip.test`), which lives in the parent zone in
our design. `lua-records-exec-limit=20000` is required: with the default (1000) 86
queries fail.

```sh
docker network create pdnstest
docker run -d --name sslip-t --network pdnstest cunnie/sslip.io-dns-server@sha256:0c51490361aa5b5682b766d0d9e0e6644fc4a475b90e55e39a5a5b2a41503397 \
  -ns .=ns1-ip.test. -soa ns1-ip.test.,dns.test.,1,900,900,604800,60 -a ns1-ip.test=10.9.9.9
printf 'enable-lua-records=yes\nlua-global-include-dir=/etc/powerdns/lua-global\nlua-records-exec-limit=20000\n' > lua.conf
docker run -d --name pdns-t --network pdnstest -v "$PWD/lua.conf:/etc/powerdns/pdns.d/lua.conf:ro" \
  -v "$PWD/../../deploy/secondary/lua:/etc/powerdns/lua-global:ro" powerdns/pdns-auth-51:5.1.5
docker exec pdns-t sh -c 'pdnsutil zone create ip.test ns1-ip.test &&
  pdnsutil rrset add ip.test "*.ip.test" LUA "A \";return ipname4()\"" &&
  pdnsutil rrset add ip.test "*.ip.test" LUA "AAAA \";return ipname6()\"" && pdns_control rediscover'
docker run --rm -i --network pdnstest -v "$PWD:/w:ro" alpine:3.20 sh /w/diff.sh sslip-t pdns-t < corpus.txt | tail -1
```

Bind-mount host paths when the Docker engine is the host's (this workspace).
