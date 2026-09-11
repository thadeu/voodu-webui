# voodu-webui on a voodu box — the hosted console (tier=unlimited).
#
# BUILD MODE, on purpose. The hosted console deploys the working tree: the CLI
# tarballs it (honouring .dockerignore, so the signing keys, master.key and
# storage/ never leave the laptop) and the box builds the Dockerfile. It is the
# same path VooduCD takes when a push arrives — so the day this repository
# gets its own `.voodu/console.yml` pointing at runa, only the trigger changes.
#
# The published image, ghcr.io/thadeu/voodu-webui, is for SELF-HOSTED
# customers and follows its own cadence (v* tags → release.yml). It is not what
# runs here.
#
# The cost is that the build runs on the production box and competes with the
# console already serving there for a few minutes. Watch `vd stats runa/webui`
# during a build before deciding whether that matters.
#
# WHAT LIVES WHERE. With DATABASE_URL set, the PRIMARY (orgs, users, servers,
# encrypted PATs, deployments, webhook receipts) moves to Postgres. Cache,
# queue, cable, metrics and hep stay as SQLite files, and SECRET_KEY_BASE plus
# the ActiveRecord encryption keys are generated on first boot INTO THE SAME
# VOLUME. Lose the volume and every PAT in Postgres becomes unreadable — the
# volume is not a cache, back it up with the database.
#
# Secrets are NOT here. Every value in `env` below is safe to commit; the rest
# is set once with `vd config runa/webui set …` (see the checklist beside this
# file) and stacked on top of these at runtime.

deployment "voodu" "web" {
  build {
    context    = "."
    dockerfile = "Dockerfile"
  }

  replicas = 1
  ports    = ["3000"]

  volumes = ["voodu-webui-storage:/rails/storage"]

  env = {
    RAILS_ENV                   = "production"
    # TLS terminates at the caddy ingress below; Thruster stays plain HTTP.
    TLS_DOMAIN                  = ""
    SOLID_QUEUE_IN_PUMA         = "1"
    POLLER_INTERVAL_SECONDS     = "15"
    POLLER_LOG_BACKFILL_SECONDS = "86400"
    # Per-person sign-in. The app refuses to boot with this on and no
    # CLOWK_PUBLISHABLE_KEY — set the keys before the first apply.
    CLOWK_ENABLED               = "1"
    RAILS_LOG_LEVEL             = "info"
  }

  probes {
    # Rails cold boot with bootsnap and five db:prepare runs is not 2 seconds.
    startup {
      http_get { path = "/up" port = 3000 }
      period            = "3s"
      failure_threshold = 40
    }

    liveness {
      http_get { path = "/up" port = 3000 }
      period            = "15s"
      failure_threshold = 3
    }

    readiness {
      http_get { path = "/up" port = 3000 }
      period = "10s"
    }
  }
}

# Public host. GitHub has to reach /integrations/github/webhook over HTTPS,
# and the deploy plane is only as reliable as this hostname.
ingress "runa" "webui" {
  host    = "console.voodu.clowk.in"
  service = "webui"

  tls {
    email = "ops@clowk.in"
  }
}
