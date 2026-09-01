# frozen_string_literal: true

# Server represents one voodu controller the WebUI talks to.
#
# Each Server carries:
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
class Server < ApplicationRecord
  include UniqueShortKeyable

  # Default voodu observability-plane port. The operator usually only
  # types the IP; we splice this in if no explicit port is present.
  DEFAULT_PORT = 8687

  # ActiveRecord Encryption — Rails encrypts the column at write,
  # decrypts on read. Operator never has to think about it.
  encrypts :pat_ciphertext

  # Every server belongs to exactly one Org (the server/grouping layer above
  # servers). Required — no orphan servers; the registration form always
  # picks or creates an org. See app/models/org.rb.
  belongs_to :org

  # Local snapshots maintained by the poller's state stream (every ~15s).
  # Pages read from these instead of making a fresh HTTP call to
  # the controller — page-instant render + offline resilience. See
  # `app/services/server_state.rb` for the read facade and
  # `app/services/pod_snapshot.rb` / `system_snapshot.rb` for the
  # writers.
  #
  # `dependent: :destroy` keeps snapshot tables tidy: removing an
  # Server purges its row sets in the same transaction (also enforced
  # at the DB level via `foreign_key: { on_delete: :cascade }`).
  has_many :pods, dependent: :destroy
  has_one :system, dependent: :destroy

  # Alert rules + their firing episodes. server_id on both is the TARGET server
  # (a rule monitors this server; an event fired on it), so these stay direct.
  # Destinations moved to the org (M3) — a webhook is shared org-wide, not per
  # server — so there's no server→destinations association any more.
  has_many :alert_rules, dependent: :destroy
  has_many :alert_events, dependent: :destroy

  before_validation :normalize_endpoint

  # No "sync right now" kick on creation. The poller re-reads the server list
  # from Internal::PollerController on every tick, so a new server is picked
  # up within one interval (~15s); until then its pages render "—", which is
  # the truth. The Ruby jobs this used to enqueue were already no-ops under
  # the poller before they were removed.

  # Unique per ORG, not globally: a global index would answer "has already been
  # taken" for another tenant's server name, and would block two customers from
  # both owning a box called "web-1". Mirrors AlertDestination.
  validates :name, presence: true, uniqueness: {scope: :org_id}, length: {maximum: 64}
  validates :endpoint, presence: true, format: {
    with: %r{\Ahttps?://[^/]+:\d+\z}, message: "could not be normalised to scheme://host:port"
  }
  validates :pat_ciphertext, presence: true
  validates :key, presence: true, uniqueness: true, format: {with: /\A[a-zA-Z0-9]{6}\z/}

  # 6-char base62 URL key (~56 bits): hand-typeable + URL-clean, opaque in
  # bookmarks. Generated + kept unique by UniqueShortKeyable.
  unique_short_key :key, length: 6

  # Convenience accessor — read/write as `server.pat` even though
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

  # plugin_installed? — does this server's controller have the named
  # plugin installed (matching its canonical name or any alias)? Reads
  # the locally-synced System row (the poller's state stream, ~15s), so feature
  # gates resolve offline and free at render time. False when no system
  # snapshot has landed yet.
  def plugin_installed?(name)
    system&.plugin_installed?(name) || false
  end

  # pods_count — total pod count for the sidebar's row sub-text.
  #
  # A SQL COUNT over the local snapshot, which the state-sync job keeps
  # fresh, so the sidebar shows an accurate count for EVERY server —
  # not just the one whose overview the operator opened last.
  def pods_count
    pods.count
  end

  # status — :online | :offline. Read from ServerHealth's cache.
  #
  # First read after cache expiry triggers a synchronous probe (one
  # HTTP round-trip to /api/pat/v1/system). With TTL 30s and typical
  # 1–3 servers per operator, this is negligible cost; the upside is
  # the sidebar and topbar show truth instead of a hardcoded :online.
  #
  # OverviewData.fetch! warms this cache as a side effect of its
  # /system call — so navigating the dashboard normally keeps the
  # status fresh without spending dedicated probes.
  def status
    ServerHealth.status_for(self)
  end

  # region — operator-supplied label rendered in the topbar chip
  # ("fra1", "us-east-1", "homelab"). Stored in its own column;
  # nil/blank means "operator didn't tag this server" and the
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

  # Beyond this the host snapshot is too old to trust as "live" — used
  # to blank the uptime instead of showing the value captured before a
  # reboot. Keyed on the snapshot's own age (System#synced_at), NOT on
  # server.status, which flips Online via the fast /health check while
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
    system&.uptime_seconds
  end

  # live_uptime_seconds — derives uptime from the absolute boot
  # timestamp so it ticks up between 10s syncs and reads the same on
  # every page. Returns nil (→ "—") when the snapshot is stale or
  # missing, so a just-rebooted box doesn't show its PRE-reboot uptime.
  def live_uptime_seconds
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

  # to_param — Rails uses this to interpolate the model into routes.
  # Returning `key` instead of `id` means the URL stays opaque even
  # when we use `server_path(server)` (rather than building the URL
  # by hand). The route constraint matches the same shape.
  def to_param
    key
  end

  private

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
