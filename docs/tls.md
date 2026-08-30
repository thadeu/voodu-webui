# TLS

Yes, it is automatic — one variable, and the certificate is issued, installed
and renewed for you:

```sh
TLS_DOMAIN=console.example.com
```

Thruster ships inside the image, requests a Let's Encrypt certificate for that
name, redirects HTTP to HTTPS, and renews before expiry. There is no certbot to
run and no cron to add.

What is *not* automatic is the three things that have to be true first. Every
"it didn't work" below is one of them.

## The three conditions

**1. An A (or AAAA) record for the name points at this host.**

```sh
dig +short console.example.com     # must return this machine's public IP
```

**2. Ports 80 and 443 are both open from the internet.** Port 443 is obvious.
Port 80 is not optional: Let's Encrypt proves you control the name by fetching a
file over plain HTTP on 80 (the HTTP-01 challenge). Firewall it and the
certificate is never issued.

**3. Nothing else terminates TLS in front.** Two proxies both trying to hold the
certificate is the most common cause of a working DNS record and a broken site.
See [Behind Cloudflare](#behind-cloudflare).

Leave `TLS_DOMAIN` empty and you get plain HTTP with no certificate, which is
the right answer when something in front already handles it.

## Ports: the mistake that looks like a TLS bug

The container listens on **3000 for HTTP** and **443 for HTTPS**. Map them
straight across:

```yaml
ports:
  - "80:3000"     # HTTP — also where the ACME challenge lands
  - "443:443"     # HTTPS
```

```sh
docker run -d -p 80:3000 -p 443:443 \
  -e TLS_DOMAIN=console.example.com \
  -v voodu:/rails/storage ghcr.io/thadeu/voodu-webui
```

**Mapping `443:3000` gives `ERR_SSL_PROTOCOL_ERROR`.** The browser opens a TLS
handshake and gets plain HTTP back, because 3000 is the plaintext listener. The
error names SSL, so it reads like a certificate problem; it is a port mapping
problem. If you see that error, check this before anything else.

Compose reads `HOST_HTTP_PORT` and `HOST_HTTPS_PORT` if you need different host
ports — but keep 80 reachable while a certificate is being issued.

## Checking it worked

```sh
docker logs voodu-webui 2>&1 | grep -i "acme\|certificate\|tls"
curl -sI https://console.example.com | head -1
echo | openssl s_client -connect console.example.com:443 -servername console.example.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

The issuer should say Let's Encrypt and `notAfter` should be about 90 days out.

## While DNS or the firewall is still wrong

Let's Encrypt rate-limits failures, and burning the production limit means
waiting hours. Point at staging while you sort it out:

```sh
ACME_DIRECTORY=https://acme-staging-v02.api.letsencrypt.org/directory
```

The browser will warn that the certificate is untrusted — that is what staging
certificates are, and it means the mechanism works. Remove the variable and
restart to get a real one.

## Behind Cloudflare

An orange-cloud (proxied) record **breaks HTTP-01**: Cloudflare answers the
challenge itself, so the issuance never reaches this container. Two ways out,
and you must pick one:

- **Leave `TLS_DOMAIN` empty** and let Cloudflare hold the certificate. Set the
  SSL mode to Full so the hop to your origin is not plaintext across the
  internet.
- **Set the record to DNS-only** (grey cloud) and let Thruster hold it.

The same reasoning applies to any proxy in front — an ALB, an nginx, a Caddy you
already run. Whoever terminates TLS owns the certificate; two owners is a broken
site.

## Renewal, and why the volume matters

Certificates live in `/rails/storage/thruster`. Keep the volume and a restart
reuses them; lose it and the container asks Let's Encrypt for a new one on next
boot — which works, until you have done it enough times in a week to hit the
rate limit.

Renewal is automatic and needs port 80 to stay open. A firewall tightened months
after setup is the classic way a working site expires.

## With the Basic Auth overlay

`docker-compose.auth.yml` puts Caddy in front for a password prompt. Caddy then
owns the certificate and reads the same `TLS_DOMAIN`, so nothing changes for
you — but Thruster must not also try, which the overlay handles.

Basic Auth is a shared password, not identity. It is a reasonable lock on a
staging box and not a substitute for the perimeter described in
[self-hosted.md](self-hosted.md), nor for [SSO](sso.md).

## When it does not work

| symptom | almost always |
|---|---|
| `ERR_SSL_PROTOCOL_ERROR` | host 443 mapped to container 3000 instead of 443 |
| Connection times out on 443 | port not open, or `TLS_DOMAIN` empty so nothing listens |
| Certificate never issues, logs mention the challenge | port 80 closed, or a proxy answering it |
| `NET::ERR_CERT_AUTHORITY_INVALID` | `ACME_DIRECTORY` still pointing at staging |
| Worked, then expired | port 80 closed after setup, so renewal could not run |
| Redirect loop | something in front already terminates TLS and forwards HTTP |
| Fresh certificate every restart | the storage volume is not persisted |
