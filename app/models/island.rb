# frozen_string_literal: true

# Island represents one voodu controller the WebUI talks to.
#
# Each Island carries:
#
#   - `name`     — operator-supplied label (sidebar display).
#   - `endpoint` — full URL of the controller's PAT plane,
#                  e.g. `http://203.0.113.10:8687`.
#   - `pat`      — the Personal Access Token used in
#                  `Authorization: Bearer <pat>`. Stored encrypted at
#                  rest via ActiveRecord Encryption.
#
# Static helpers (`host`, `pods_count`, `status`) feed the sidebar
# row without going to the network — `pods_count` is a cheap derived
# field cached in the future; for M3 it returns 0 (M4 caches live).
class Island < ApplicationRecord
  # Default voodu observability-plane port. The operator usually only
  # types the IP; we splice this in if no explicit port is present.
  DEFAULT_PORT = 8687

  # ActiveRecord Encryption — Rails encrypts the column at write,
  # decrypts on read. Operator never has to think about it.
  encrypts :pat_ciphertext

  # Local snapshots maintained by `StateSyncIslandJob` (every 10s).
  # Pages read from these instead of making a fresh HTTP call to
  # the controller — page-instant render + offline resilience. See
  # `app/services/island_state.rb` for the read facade and
  # `app/services/pod_snapshot.rb` / `system_snapshot.rb` for the
  # writers.
  #
  # `dependent: :destroy` keeps snapshot tables tidy: removing an
  # Island purges its row sets in the same transaction (also enforced
  # at the DB level via `foreign_key: { on_delete: :cascade }`).
  has_many :pods, dependent: :destroy
  has_one :system, dependent: :destroy

  # Saved metric dashboards (named multi-panel views on /metrics).
  # `dependent: :destroy` reaps them with the island; the DB foreign
  # key cascades too.
  has_many :metric_dashboards, dependent: :destroy

  # Alert rules + their firing episodes. Events also cascade through
  # alert_rules, but the direct association lets the /alerts history
  # render island-wide without joining rules.
  has_many :alert_rules, dependent: :destroy
  has_many :alert_events, dependent: :destroy
  has_many :alert_destinations, dependent: :destroy

  before_validation :normalize_endpoint
  before_validation :ensure_key, on: :create

  # Kick the first sync jobs immediately on island creation. Without
  # this, a newly-added island would wait up to 10s (state) / 14s
  # (metrics) for the next orchestrator tick before pages stop
  # rendering "—". Both jobs are no-op-safe / idempotent, so this
  # and the orchestrators can both fire without double-work.
  after_create_commit { MetricsSyncIslandJob.perform_later(id) }
  # StateSyncIslandJob ships in C4 — guarded so this commit (C2)
  # boots cleanly without the job class on disk yet.
  after_create_commit do
    StateSyncIslandJob.perform_later(id) if defined?(StateSyncIslandJob)
  end

  validates :name, presence: true, uniqueness: true, length: {maximum: 64}
  validates :endpoint, presence: true, format: {
    with: %r{\Ahttps?://[^/]+:\d+}, message: "could not be normalised to scheme://host:port"
  }
  validates :pat_ciphertext, presence: true
  validates :key, presence: true, uniqueness: true, format: {with: /\A[a-zA-Z0-9]{6}\z/}

  # URL key alphabet. base62 (0-9, A-Z, a-z) chosen over base64 because
  # `/+=` are URL-significant and url-safe-base64 (`-_`) adds visual
  # noise. base62 is the sweet spot for hand-typeable + URL-clean.
  KEY_ALPHABET = ("0".."9").to_a + ("A".."Z").to_a + ("a".."z").to_a
  KEY_LENGTH = 6

  # Convenience accessor — read/write as `island.pat` even though
  # the column is named pat_ciphertext (the name tells anyone reading
  # the schema "this is encrypted, don't grep for the plaintext").
  alias_attribute :pat, :pat_ciphertext

  # Extracts the host:port portion of the endpoint for sidebar display.
  # `http://203.0.113.10:8687` → `203.0.113.10:8687`.
  def host
    URI.parse(endpoint).then { |u| [u.host, u.port].compact.join(":") }
  rescue URI::InvalidURIError
    endpoint
  end

  # plugin_installed? — does this island's controller have the named
  # plugin installed (matching its canonical name or any alias)? Reads
  # the locally-synced System row (StateSyncIslandJob, 10s), so feature
  # gates resolve offline and free at render time. False when no system
  # snapshot has landed yet.
  def plugin_installed?(name)
    system&.plugin_installed?(name) || false
  end

  # pods_count — total pod count for the sidebar's row sub-text.
  #
  # WAREHOUSE=1 → reads `pods.count` directly (SQL COUNT, sub-ms).
  # The state-sync job (every 10s) keeps the table fresh, so the
  # sidebar shows accurate counts for EVERY island — not just the
  # one the operator most recently opened the overview for.
  #
  # WAREHOUSE=0 → legacy: reads a Rails.cache key OverviewData
  # warms after its /pods fetch. Returns nil when the operator has
  # never opened the dashboard for this island since boot, and
  # the sidebar renders "—" instead of "0".
  def pods_count
    return pods.count if IslandState.warehouse?

    Rails.cache.read(self.class.pods_count_cache_key(id))
  end

  # Class-level cache-key + writer so OverviewData (and any future
  # consumer) can warm the count by id alone, without needing an
  # Island instance. Same id-keyed pattern IslandHealth uses.
  def self.pods_count_cache_key(island_id)
    "voodu:pods_count:v1:island:#{island_id}"
  end

  def self.write_pods_count(island, count, ttl: 30.seconds)
    Rails.cache.write(pods_count_cache_key(island.id), count.to_i, expires_in: ttl)
  end

  # status — :online | :offline. Read from IslandHealth's cache.
  #
  # First read after cache expiry triggers a synchronous probe (one
  # HTTP round-trip to /api/pat/v1/system). With TTL 30s and typical
  # 1–3 islands per operator, this is negligible cost; the upside is
  # the sidebar and topbar show truth instead of a hardcoded :online.
  #
  # OverviewData.fetch! warms this cache as a side effect of its
  # /system call — so navigating the dashboard normally keeps the
  # status fresh without spending dedicated probes.
  def status
    IslandHealth.status_for(self)
  end

  # region — operator-supplied label rendered in the topbar chip
  # ("fra1", "us-east-1", "homelab"). Stored in its own column;
  # nil/blank means "operator didn't tag this island" and the
  # topbar omits the chip rather than fabricating one.
  #
  # No validation — operators use whatever vocabulary fits their
  # mental model. Two operators looking at the same VPS may give it
  # different labels and that's fine.
  #
  # The column reader is auto-generated by ActiveRecord; this
  # override exists only to surface "—" as a UI sentinel when the
  # value is blank (handy when the topbar needs SOMETHING to render
  # but the operator chose to leave the field empty).
  def region
    self[:region].presence || "—"
  end

  # infra — paired with region for the topbar's secondary chip
  # ("hetzner", "aws", "bare-metal"). Same conventions as region:
  # free-text, optional, no validation. The topbar renders both
  # next to each other when both are set; if one is blank the
  # other still shows on its own.
  def infra
    self[:infra].presence
  end

  # uptime — humanized "Nd Nh" string surfaced in the topbar chip.
  #
  # WAREHOUSE=1 → reads `system.uptime_seconds` directly from the
  # local snapshot maintained by `StateSyncIslandJob`. Every page
  # gets the live uptime, even ones the operator has never opened
  # for this island.
  #
  # WAREHOUSE=0 → legacy Rails.cache lookup that OverviewData
  # warms after its /system fetch. Returns "—" when no snapshot
  # exists yet.
  # Beyond this the host snapshot is too old to trust as "live" — used
  # to blank the uptime instead of showing the value captured before a
  # reboot. Keyed on the snapshot's own age (System#synced_at), NOT on
  # island.status, which flips Online via the fast /health check while
  # the heavier /system snapshot is still catching up after a boot.
  UPTIME_FRESH_WINDOW = 60.seconds

  # uptime — the ONE humanized uptime label, used by both the topbar
  # chip (every page) and OverviewData. Single source so /overview and
  # /metrics never disagree.
  def uptime
    secs = live_uptime_seconds
    return "—" if secs.nil? || secs <= 0

    self.class.humanize_uptime(secs)
  end

  # uptime_seconds_from_source — the raw snapshot number (no boot-time
  # derivation), for callers that want their own format.
  def uptime_seconds_from_source
    if IslandState.warehouse?
      system&.uptime_seconds
    else
      Rails.cache.read(self.class.uptime_cache_key(id))
    end
  end

  # live_uptime_seconds — derives uptime from the absolute boot
  # timestamp so it ticks up between 10s syncs and reads the same on
  # every page. Returns nil (→ "—") when the snapshot is stale or
  # missing, so a just-rebooted box doesn't show its PRE-reboot uptime.
  def live_uptime_seconds
    unless IslandState.warehouse?
      return Rails.cache.read(self.class.uptime_cache_key(id))
    end

    snap = system
    return nil if snap.nil?
    return nil if snap.synced_at.nil? || snap.synced_at < UPTIME_FRESH_WINDOW.ago

    boot = snap.booted_at
    return snap.uptime_seconds if boot.nil?

    [(Time.current - boot).to_i, 0].max
  end

  # humanize_uptime — "Nd Nh" / "Nh Nm" / "Nm" / "Ns" cascade. Class
  # method so any surface can format consistently.
  def self.humanize_uptime(secs)
    days = secs / 86_400
    hours = (secs % 86_400) / 3600
    mins = (secs % 3600) / 60

    return "#{days}d #{hours}h" if days.positive?
    return "#{hours}h #{mins}m" if hours.positive?
    return "#{mins}m" if mins.positive?

    "#{secs}s"
  end

  # Class-level cache-key + writer so OverviewData (the canonical
  # writer) can warm the value by id alone, without needing an
  # Island instance. Same id-keyed shape used by IslandHealth and
  # write_pods_count above.
  def self.uptime_cache_key(island_id)
    "voodu:uptime:v1:island:#{island_id}"
  end

  def self.write_uptime_seconds(island, seconds, ttl: 30.seconds)
    Rails.cache.write(uptime_cache_key(island.id), seconds.to_i, expires_in: ttl)
  end

  # generate_unique_key — picks a random 6-char base62 string that
  # isn't already used. Race-safe enough for a single-operator WebUI:
  # the unique index on `key` is the real guard; this loop just keeps
  # collisions from turning into RecordNotUnique exceptions at save.
  # At 6 chars (~56 bits) the loop runs once in practice — even with
  # 10k islands the first attempt collision probability is ~10^-12.
  def self.generate_unique_key
    loop do
      candidate = Array.new(KEY_LENGTH) { KEY_ALPHABET.sample }.join
      break candidate unless exists?(key: candidate)
    end
  end

  # to_param — Rails uses this to interpolate the model into routes.
  # Returning `key` instead of `id` means the URL stays opaque even
  # when we use `island_path(island)` (rather than building the URL
  # by hand). The route constraint matches the same shape.
  def to_param
    key
  end

  private

  # ensure_key — populates `key` on first save so the validation
  # passes. Idempotent: never overwrites an existing key (immutable
  # by design — keys land in operators' browser bookmarks, can't
  # silently change).
  def ensure_key
    self.key ||= self.class.generate_unique_key
  end

  # normalize_endpoint — turn operator-friendly input into a fully-
  # qualified URL the HTTP client can consume.
  #
  # Accepted inputs (all normalise to `http://1.2.3.4:8687`):
  #
  #   1.2.3.4
  #   1.2.3.4:8687
  #   http://1.2.3.4
  #   http://1.2.3.4:8687
  #
  # Rules:
  #   - Missing scheme → prepend "http://" (operators don't think in
  #     schemes for an IP-addressable controller).
  #   - Missing explicit port → append ":#{DEFAULT_PORT}" right after
  #     the host. URI's "default scheme port" (80/443) does NOT count
  #     as explicit — we want the WebUI default of 8687 to win.
  #   - Custom port (e.g. operator firewalls the plane to a non-default
  #     port) → respected verbatim.
  def normalize_endpoint
    return if endpoint.blank?

    raw = endpoint.strip

    # 1. Ensure scheme.
    raw = "http://#{raw}" unless raw.match?(%r{\Ahttps?://})

    # 2. Ensure explicit port. Regex matches scheme + host (no path,
    # no query, no fragment, no `:` already). Inserts `:8687` right
    # before the path/end. We don't run unless no explicit :digits
    # appears in the authority component.
    has_port = raw.match?(%r{\Ahttps?://[^/?#]+:\d+})

    unless has_port
      raw = raw.sub(%r{\A(https?://[^/:?#]+)}, "\\1:#{DEFAULT_PORT}")
    end

    self.endpoint = raw
  rescue
    # Anything weird — leave the original value in place so the
    # format validator surfaces a clear error to the operator.
  end
end
