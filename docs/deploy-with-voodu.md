# Deploying with voodu

The dashboard can be deployed by the controller it manages. You get the same
things every other app on that box gets — rollouts, health gating, TLS at the
ingress, `vd logs` — instead of a `docker run` you have to remember.

## The manifest

`web.voodu`, at the root of wherever you keep your infra manifests:

```hcl
// voodu-webui — the operator dashboard, deployed by the controller it watches.
//
// Single replica on purpose. The Go poller runs inside this process
// (POLLER_SPAWN=1) and the storage volume is single-writer SQLite: a second
// replica would spawn a second poller and both would write the same files.
// This is a control plane for a handful of servers, not a tier that scales.

deployment "ops" "voodu-webui" {
  image    = "ghcr.io/thadeu/voodu-webui:0.2.0"
  replicas = 1

  // HTTP only. TLS is terminated at the ingress below, so the container never
  // needs its own 443 listener — see the TLS note further down.
  ports = ["3000"]

  // Everything that must outlive the container: the six SQLite databases, the
  // NDJSON log tree, and — worth more than either — the ActiveRecord
  // encryption keys. Lose those and every stored PAT is unreadable.
  //
  // A named volume on a `deployment` is never removed by the controller;
  // `vd delete --prune` only reclaims per-pod volumes on statefulsets, and
  // only after the operator opts in.
  volumes = ["voodu-webui-storage:/rails/storage"]

  env = {
    // TLS_DOMAIN is deliberately ABSENT. The ingress holds the certificate;
    // setting it here would have two things trying to own it, which is the
    // most common way a correct DNS record still produces a broken site.

    // Sign-in. Leave both out for anonymous mode behind your perimeter.
    // CLOWK_ENABLED         = "1"
    // CLOWK_PUBLISHABLE_KEY = "pk_live_…"

    // Enterprise licence. Or paste it at /ops/license once running.
    // VOODU_LICENSE = "eyJhbGciOiJSUzI1NiJ9…"

    // Control plane in Postgres. Without it, all six databases are SQLite
    // in the volume above.
    // DATABASE_URL = "postgres://voodu:…@10.0.0.5:5432/voodu"

    // Days of telemetry kept on disk. The licence caps how far back you can
    // search; this decides what there is to search. See docs/database.md.
    VOODU_RETENTION_DAYS = "30"
  }

  probes {
    // /up is rails/health#show and carries no session, which is why it is
    // reachable in every auth mode.
    readiness {
      http_get {
        path = "/up"
        port = 3000
      }

      period            = "5s"
      failure_threshold = 1
      success_threshold = 2
    }

    liveness {
      http_get {
        path = "/up"
        port = 3000
      }

      // Generous, because boot runs db:prepare: on first start that creates
      // six databases and loads their schemas, and after an upgrade it applies
      // pending migrations. Restarting mid-migration is how you get a
      // half-applied schema.
      initial_delay     = "60s"
      period            = "15s"
      failure_threshold = 4
    }
  }

  resources {
    limits {
      cpu    = "1"
      memory = "1Gi"
    }
  }
}

ingress "ops" "voodu-webui" {
  host = "console.example.com"

  tls {
    enabled  = true
    provider = "letsencrypt"
    email    = "ops@example.com"
  }
}
```

```sh
vd apply -f web.voodu
```

## TLS: the ingress owns it

This is the one thing to get right, and it is the third condition in
[tls.md](tls.md): **whoever terminates TLS owns the certificate, and two owners
is a broken site.**

Deploying this way, the ingress terminates. So `TLS_DOMAIN` must NOT be set on
the container — Thruster would try for a Let's Encrypt certificate of its own,
against a port 80 the ingress is already answering. The manifest above leaves it
out, and that absence is deliberate rather than an oversight.

The container therefore only listens on 3000, and `ports = ["3000"]` is the
whole story. No 443 anywhere in the manifest.

## Sizing

The memory limit matters more than the CPU one. `solid_queue` runs inside Puma
(`SOLID_QUEUE_IN_PUMA=1`), the Go poller is a second process in the same
container, and the metrics warehouse writes in batches. 1Gi is comfortable for a
handful of servers; watch it if you are polling dozens.

The volume grows with `VOODU_RETENTION_DAYS`. It is SQLite on a disk, so
"unlimited" is a disk that fills and a container that stops — pick a number you
have room for.

## Upgrading

```sh
# bump the tag, then
vd apply -f web.voodu
```

Migrations run on boot and are idempotent. Keep the volume and nothing else is
needed — the liveness `initial_delay` above is what stops a long migration from
looking like a hang.

## Where this leaves you

The dashboard is now a deployment like any other on that host: `vd logs ops
voodu-webui`, `vd rollback`, health-gated rollouts. Which does mean the box that
runs your dashboard is a box your dashboard manages — fine, and worth knowing
before you use it to debug that box being down.

Next:

- [self-hosted.md](self-hosted.md) — the perimeter, and what the volume holds
- [tls.md](tls.md) — when the container holds the certificate instead
- [database.md](database.md) — moving the control plane to Postgres
