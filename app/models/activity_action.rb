# frozen_string_literal: true

# ActivityAction — local warehouse row for one operator action performed on a
# voodu controller: an apply, a restart, a delete, a rollback, a config change.
#
# The controller records these as append-only NDJSON (`internal/activity` on
# the Go side) and serves them over the PAT plane; the poller tails
# `/activity/dump` and hands the lines here. One row per ACTION — the
# `started` and `finished` lines of a long action merge into a single row. See
# db/metrics_migrate/*_create_activity_actions.rb for why.
#
# Lives in the `metrics` database with MetricSample: same writer, same
# lifecycle, low volume.
#
# Vocab:
#   - `activity_id` is the controller's correlation id, unique per action.
#   - `actor` is the PAT id, present only for actions that crossed the PAT
#     plane. A CLI on the box itself has no PAT, so `actor` is blank and
#     `origin` is what identifies it. That is a fact of the design, not a gap.
#
# Cross-DB note: no `belongs_to :server` — Server lives in the primary DB.
# Callers pass a Server object (see ServerScoped), never a bare id.
class ActivityAction < MetricsRecord
  include PayloadParsable

  extend ServerScoped

  # EVENT_RANK mirrors the controller's three event values. Higher wins on a
  # merge, so a re-delivered `started` cannot revert a closed action to
  # in-flight. Written as a real column because the upsert compares it against
  # the incoming row.
  EVENT_RANK = {
    "started" => 0,
    "finished" => 1,
    "done" => 2
  }.freeze

  # ORPHAN_AFTER — how long a lone `started` may claim to be running.
  #
  # A `started` with no `finished` means one of two things: the action is in
  # flight, or the controller died mid-action. Both look identical on disk, and
  # only time separates them. Past this, the screen reads the row as `unknown`
  # rather than leaving something "running" forever — an action still going
  # after an hour is not a state anyone should trust the label of.
  #
  # Computed on READ, never written: a row that ages into unknown must age back
  # out the moment its `finished` line arrives.
  ORPHAN_AFTER = 1.hour

  IN_FLIGHT = "running"
  UNKNOWN = "unknown"

  # last_ts_for — newest action ts (unix seconds) warehoused for this server.
  # Internal::PollerController#activity_watermark serves it so the poller can
  # resume `?since=` after a restart instead of cold-starting.
  #
  # 0 on an empty warehouse; the poller reads that as "nothing to backfill".
  # Takes a Server, never an id — see ServerScoped.
  def self.last_ts_for(server)
    where(server_id: server_id_of(server)).maximum(:ts_epoch) || 0
  end

  # ── Scopes ──────────────────────────────────────────────────────
  #
  # Every one of these hits an index declared in the migration. They take
  # raw values because the controller has already resolved the Server.

  # The ordering every read uses, and the one the cursor is built on:
  # (ts_epoch, id) is stable and unique, so a page boundary names exactly one
  # row and cannot drift when new ones land above it.
  scope :recent_first, -> { order(ts_epoch: :desc, id: :desc) }

  # Reversed, for walking BACKWARDS to the previous page. The caller flips the
  # result so the page still reads newest-first.
  scope :oldest_first, -> { order(:ts_epoch, :id) }

  # older_than / newer_than — the cursor comparison, written out rather than as
  # a row-value `(ts_epoch, id) < (?, ?)`. Both forms work on modern SQLite;
  # this one is readable in a log and does not depend on a version.
  #
  # The id tiebreak is not decoration: several actions can share a second, and
  # comparing on ts alone would either repeat them across pages or skip them.
  scope :older_than, ->(ts, id) {
    where("ts_epoch < :ts OR (ts_epoch = :ts AND id < :id)", ts: ts.to_i, id: id.to_i)
  }

  scope :newer_than, ->(ts, id) {
    where("ts_epoch > :ts OR (ts_epoch = :ts AND id > :id)", ts: ts.to_i, id: id.to_i)
  }

  scope :range, ->(from:, to:) { where(ts_epoch: from.to_i..to.to_i) }

  scope :with_action, ->(actions) { where(action: Array(actions)) }

  scope :with_origin, ->(origins) { where(origin: Array(origins)) }

  scope :with_scope, ->(scope_name) { where(scope: scope_name) }

  # in_flight — actions that opened and never closed. `event_rank` rather than
  # `status IS NULL`: a started line has no status at all, and asking for the
  # absence of a JSON key is a different query from asking for the event.
  scope :in_flight, -> { where(event_rank: EVENT_RANK["started"]) }

  # matching — free text over the whole recorded line.
  #
  # Against `payload` and not a list of columns, because "any word" means the
  # ones that are NOT columns: a resource name inside the batch, a config key,
  # an IP, the city the operator was in. A column list would answer for four of
  # those and silently miss the rest, which is the kind of search that teaches
  # people not to trust it.
  #
  # No index can serve a leading-wildcard LIKE, so this scans — bounded by the
  # time window already applied, over a store holding dozens of rows a day for
  # thirty days. If activity ever grows to where that hurts, the answer is
  # SQLite FTS over payload, not a narrower search.
  #
  # `_` and `%` are escaped: config keys are full of underscores (PG_SHARED_USER),
  # and unescaped each one would quietly match any character.
  scope :matching, ->(text) {
    term = sanitize_sql_like(text.to_s.strip)
    next all if term.empty?

    where("payload LIKE ? ESCAPE '\\'", "%#{term}%")
  }

  # with_status accepts the two READ-TIME states alongside the three the
  # controller writes, because that is what the screen's filter offers. The
  # first two have no stored value to match, so they are expressed as the
  # event + age question they actually are.
  scope :with_status, ->(statuses, now: Time.current) {
    wanted = Array(statuses).map(&:to_s)
    stored = wanted - [IN_FLIGHT, UNKNOWN]

    clauses = []
    clauses << where(status: stored) if stored.any?

    if wanted.include?(IN_FLIGHT)
      clauses << in_flight.where(ts_epoch: (now - ORPHAN_AFTER).to_i..)
    end

    if wanted.include?(UNKNOWN)
      clauses << in_flight.where(ts_epoch: ...(now - ORPHAN_AFTER).to_i)
    end

    clauses.reduce { |acc, rel| acc.or(rel) } || none
  }

  # ── Read accessors ──────────────────────────────────────────────

  alias_method :payload_json, :parsed_payload

  # effective_status — what the screen shows in the status column.
  #
  # Read-time, and that is the point: a stored "running" would be a claim
  # frozen at the moment it aged worst. The controller writes what it knows
  # (succeeded / failed / partial); everything else is inferred from the event
  # and the clock, here, every time.
  def effective_status(now: Time.current)
    return status if status.present?
    return UNKNOWN unless event == "started"

    (Time.at(ts_epoch).utc < (now - ORPHAN_AFTER)) ? UNKNOWN : IN_FLIGHT
  end

  def in_flight?(now: Time.current)
    effective_status(now: now) == IN_FLIGHT
  end

  # config_action? — the two actions whose row carries a key instead of a
  # resource. The screen renders them differently, and NEVER renders a value:
  # the controller does not record one, only a digest of it.
  def config_action?
    action.to_s.start_with?("config.")
  end

  # config_changes — every key ONE config command touched, as
  # [{"key" =>, "value_digest" =>}].
  #
  # Reads two shapes on purpose. The controller now writes one line per
  # COMMAND carrying `config_keys`; it used to write one line per KEY with a
  # singular `config_key`/`value_digest` pair, and those rows are still in the
  # 30-day window. The fallback ages out on its own — nothing has to migrate,
  # and deleting it early would blank the history instead of the code.
  def config_changes
    listed = payload_json["config_keys"]
    return listed if listed.is_a?(Array) && listed.any?

    legacy = payload_json["config_key"]
    return [] if legacy.blank?

    [{"key" => legacy, "value_digest" => payload_json["value_digest"]}]
  end

  def config_keys
    config_changes.filter_map { |change| change["key"].presence }
  end

  def resources
    payload_json["resources"] || []
  end

  # files — the operator's original `-f` arguments.
  #
  # Declared by the CLI on the machine the command was typed on, because by the
  # time a forwarded apply reaches the controller the argv says `-f -` and the
  # names are gone. Absent for an apply run locally on the box, which has no
  # forwarding step to carry them.
  def files
    payload_json["files"] || []
  end

  # client — who ran it, as their own machine reported.
  #
  # Nil for anything that did not come through a forwarding CLI: the controller
  # cannot observe this. Its view of a CLI peer is always 127.0.0.1, since the
  # CLI talks to the loopback port and remote work arrives over SSH to run on
  # the box. DECLARED, therefore, not verified — it answers "who ran this" for
  # a cooperating operator, and is not evidence.
  def client
    payload_json["client"]
  end

  def client_ip = client&.dig("ip")

  # client_location — "Sao Paulo, BR", or whichever halves exist. Nil rather
  # than a lone comma when the lookup returned neither.
  def client_location
    return nil if client.nil?

    [client["city"], client["country"]].compact_blank.join(", ").presence
  end

  def client_org = client&.dig("org").presence

  def error_message
    payload_json["error"]
  end

  # ts — when the action ENDED. The stored timestamp is the closing line's:
  # the `finished` row overwrites the `started` one on ingest, by design, so a
  # row holds one action rather than two halves.
  # cursor — this row as a page boundary. Plain, not encoded: it names a
  # timestamp and a row id, neither of which is a secret, and an opaque blob
  # would only make a broken URL harder to read.
  def cursor = "#{ts_epoch}:#{id}"

  # parse_cursor — (ts, id), or nil for anything that is not exactly two
  # integers. Strict because the value reaches a WHERE clause: a cursor from a
  # mangled URL must fall back to the first page, not become a query.
  def self.parse_cursor(raw)
    match = /\A(\d+):(\d+)\z/.match(raw.to_s)
    return nil if match.nil?

    [match[1].to_i, match[2].to_i]
  end

  def ts
    Time.at(ts_epoch).utc
  end

  # started_at — when the operator fired the command.
  #
  # DERIVED, not stored, and it does not need to be: `elapsed_ms` is the
  # controller's own measurement of finish minus start, taken in one process
  # off one clock. Subtracting it is exact, works for every row already in the
  # warehouse, and costs no column and no migration.
  #
  # An action with no duration — a config change, or one still running — began
  # when it was recorded, so start and end are the same moment.
  def started_at
    ms = elapsed_ms.to_i
    return ts if ms <= 0

    ts - (ms / 1000.0)
  end

  # duration — the controller's own measurement when it has one. Nil for an
  # action still in flight; deriving one from the clock would be inventing a
  # number the trail did not report.
  def duration
    ms = elapsed_ms
    return nil if ms.blank? || ms.to_i.negative?

    ms.to_i / 1000.0
  end

  # app — WHICH application the action was about: the resource for a workload
  # action, the bucket for a config one. Both are `name` on the wire.
  #
  # Split out from `target` because collapsing them answered neither question.
  # A `config.set` reported its KEY as the target and never said which app the
  # key belonged to, which is the one thing you need to know before deciding
  # whether it matters. Nil for a batch, honestly: five resources have no app.
  def app
    name.presence
  end

  # target — WHAT the action did to that app.
  #
  # The config key for a config change, the count for a batch, nothing for a
  # single-resource action where `app` already said it. Listing eight resource
  # names in a table cell is not readable; the row expands for that.
  def target
    if config_action?
      keys = config_keys

      # One key names itself; several name their count, because `vd config set
      # A=1 B=2 C=3` is one command and listing three keys in a table cell is
      # not readable. The row expands into a table for that.
      return nil if keys.empty?

      return (keys.size == 1) ? keys.first : "#{keys.size} vars"
    end

    count = resources.size
    (count > 1) ? "#{count} resources" : nil
  end
end
