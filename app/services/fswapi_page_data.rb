# frozen_string_literal: true

# FswapiPageData — the /fswapi (FreeSWITCH) page for ONE server.
#
# Two kinds of data, two paths (see .scratch/fswapi-console/PRD.md):
#
#   - counts with a history (calls, channels, sessions/s) come from the
#     warehouse samples FswapiSyncServerJob writes every 15s, through
#     MetricsData like every other sparkline;
#   - the lists (calls, channels, registrations, gateways) are current state,
#     read live from the plugin through the PAT proxy and never stored.
#
# Live reads are cached LIVE_TTL per (server, route): the frame polls, and two
# operators on the page should cost FreeSWITCH one ESL round-trip, not two.
#
# Errors never raise into the view. A FreeSWITCH that is down or refuses the
# ESL password answers 502 with a message that names the fix; that message is
# what the operator must see, so it is kept verbatim in #error.
class FswapiPageData
  VIEWS = [
    {key: "calls", label: "Calls", route: "calls"},
    {key: "channels", label: "Channels", route: "channels"},
    {key: "registrations", label: "Registrations", route: "registrations"},
    {key: "gateways", label: "Gateways", route: "sofia"}
  ].freeze

  DEFAULT_VIEW = "calls"

  LIVE_TTL = 5.seconds

  # Each card is one warehouse metric with its own palette token (CLAUDE.md:
  # 1 metric = 1 color).
  CARDS = [
    {metric: "fs_calls", label: "Active calls", icon: :PhoneOutline, color: "var(--voodu-fuchsia)", sub: "bridged calls (A↔B = 1)"},
    {metric: "fs_channels", label: "Channels", icon: :ArrowsRightLeftOutline, color: "var(--voodu-sand)", sub: "call legs (A↔B = 2)"},
    {metric: "fs_sessions_per_sec", label: "Sessions / s", icon: :BoltOutline, color: "var(--voodu-olive)", sub: nil}
  ].freeze

  # MAX_SHOWN — calls (Channels tab) or rows (other tabs) rendered at once.
  # The frame re-renders every 15s; at 500 calls the Channels tab alone would
  # be 1,500 rows per tick. Past this, the filter is how to find one call.
  MAX_SHOWN = 100

  attr_reader :server, :view, :q

  def initialize(server:, view: nil, q: nil, client: nil)
    @server = server
    @view = (VIEWS.any? { |v| v[:key] == view.to_s }) ? view.to_s : DEFAULT_VIEW
    @q = q.to_s.strip
    @client = client || Voodu::Client.new(server)
    @live = {}
  end

  def views = VIEWS

  # call_flow? — a live channel can open its SIP flow only where HEP3 captures
  # it; without the plugin the button would open onto nothing.
  def call_flow?
    server.plugin_installed?("hep3")
  end

  # ── Status (live /overview — the same call the sync job makes) ───

  def status
    live("overview")&.dig("status") || {}
  end

  def up?
    status["up"] == true
  end

  def version
    status["version"].to_s[/\d+(\.\d+)+/] || status["version"].presence
  end

  def uptime
    secs = status["uptime_seconds"].to_i

    return nil unless secs.positive?

    days, rem = secs.divmod(86_400)
    hours, rem = rem.divmod(3600)
    minutes = rem / 60

    return "#{days}d #{hours}h" if days.positive?
    return "#{hours}h #{minutes}m" if hours.positive?

    "#{minutes}m"
  end

  def idle_cpu
    v = status["idle_cpu"]

    v.nil? ? nil : format("%.1f%%", v.to_f)
  end

  # idle_cpu_percent — the free CPU as a number (idle_cpu formats it).
  def idle_cpu_percent
    status["idle_cpu"]&.to_f
  end

  # idle_cpu_floor — `min-idle-cpu` from switch.conf.xml: below this much free
  # CPU FreeSWITCH refuses new calls. 0 means the guard is off.
  def idle_cpu_floor
    status["idle_cpu_min"]&.to_f
  end

  def sessions_summary
    return nil if status.empty?

    "peak #{status["sessions_peak"].to_i} · max #{status["sessions_max"].to_i}"
  end

  # error — the plugin's own message when FreeSWITCH (or the route) could not
  # answer; nil when every live read worked. Makes the page's live reads first,
  # so it can be asked before anything else is rendered.
  def error
    status
    rows

    @live.values.find { |v| v.is_a?(LiveError) }&.message
  end

  # ── Cards (warehouse) ───────────────────────────────────────────

  # The headline is LIVE (the /overview this page already read), so it always
  # matches the tables below it; the sparkline is the warehouse history, up to
  # one 15s sample behind. The warehouse latest is the fallback when the live
  # read failed.
  def cards
    @cards ||= CARDS.map do |card|
      series = metrics.points_for(source: "fswapi", metric: card[:metric], range: "1h")
      latest = live_count(card[:metric]) || metrics.latest_for(source: "fswapi", metric: card[:metric], range: "1h")

      {
        label: card[:label], icon: card[:icon], color: card[:color],
        value: latest.nil? ? "—" : latest.to_i.to_s, unit: "",
        sub: card[:sub] || sessions_summary || "—",
        series: series
      }
    end
  end

  def history?
    cards.any? { |c| c[:series].size >= 2 }
  end

  # ── Live tables ─────────────────────────────────────────────────

  # rows — what the table renders: the live list, filtered by `q`, capped at
  # MAX_SHOWN (calls on the Channels tab, rows elsewhere). The filter runs on
  # the cached list, so typing costs no extra ESL round-trip.
  def rows
    @rows ||= shown_units.each_with_index.flat_map do |unit, i|
      (view == "channels") ? unit.map { |leg| leg.merge("_group" => i) } : unit
    end
  end

  # all_rows — the whole live list, unfiltered (Channels: grouped by call).
  def all_rows
    @all_rows ||= case view
    when "gateways" then gateway_rows
    when "channels" then self.class.group_channels(Array(live("channels")&.dig("rows")))
    else Array(live(current[:route])&.dig("rows"))
    end
  end

  # Units are what the cap and the filter count: a call (its legs together) on
  # the Channels tab, a row elsewhere. Filtering a CALL keeps both legs, so a
  # match on the B-leg's destination still shows who called.
  def total_units = units.size

  def matched_units = matching_units.size

  def shown_units
    matching_units.first(MAX_SHOWN)
  end

  def filtered? = q.present?

  def capped? = matched_units > MAX_SHOWN

  def count_for(key)
    return all_rows.size if key == view

    nil
  end

  # call_count — on the Channels tab, how many calls the legs make up.
  def call_count
    all_rows.count { |r| r["_leg"] == "a" }
  end

  # transcoding_count — calls whose legs use different codecs: FreeSWITCH
  # converts the audio of every one of them, which is CPU (see Idle CPU).
  def transcoding_count
    all_rows.count { |r| r["_transcode"] }
  end

  # decode — FreeSWITCH writes some characters of a dial string URL-encoded in
  # channel names and destinations (`0656%23552…` is `0656#552…`). Decoded for
  # reading and for the filter; ASCII only, so a stray byte stays as it was.
  def self.decode(value)
    value.to_s.gsub(/%(\h\h)/) { ((h = ::Regexp.last_match(1).hex) < 0x80) ? h.chr : ::Regexp.last_match(0) }
  end

  SEARCH_FIELDS = %w[
    cid_num cid_name dest callee_num callee_name name uuid call_uuid
    b_cid_num b_cid_name b_dest b_name b_uuid
    reg_user realm url network_ip kind data state
  ].freeze

  # group_channels — the flat `show channels` list as calls: each A-leg
  # followed by the legs bridged to it, tagged for the table (`_leg` "a"/"b",
  # `_last` on a group's final B-leg, `_group` its call's index for the
  # alternating tint, and on the A-leg `_legs` and `_b` — the call's leg count
  # and first B-leg, which the call's header row summarises).
  #
  # The key is FreeSWITCH's own: every channel starts with call_uuid = its own
  # uuid, and a bridge sets BOTH legs' call_uuid to the A-leg's uuid. So the
  # group is the call_uuid, and its A-leg is the row whose uuid equals it. When
  # that row is missing (it hung up first, or the list raced the bridge), the
  # oldest leg leads, so a group never renders headless.
  #
  # Groups keep FreeSWITCH's order of their first leg; B-legs sort oldest first
  # (a forked call's legs in the order they were dialled).
  def self.group_channels(channels)
    groups = channels.group_by { |c| c["call_uuid"].presence || c["uuid"] }

    groups.each_with_index.flat_map do |(call_uuid, legs), group|
      lead = legs.find { |c| c["uuid"] == call_uuid } || legs.min_by { |c| c["created_epoch"].to_i }
      others = (legs - [lead]).sort_by { |c| c["created_epoch"].to_i }

      a = lead.merge("_leg" => "a", "_group" => group, "_legs" => legs.size, "_b" => others.first,
        "_transcode" => transcode(lead, others.first))

      [a] + others.each_with_index.map do |c, i|
        c.merge("_leg" => "b", "_group" => group, "_last" => i == others.size - 1)
      end
    end
  end

  # transcode — [a_codec, b_codec] when the two legs of a call read different
  # codecs, else nil.
  def self.transcode(a, b)
    return nil unless b

    codecs = [a["read_codec"], b["read_codec"]].map { |c| c.to_s.strip }

    return nil if codecs.any?(&:empty?) || codecs.uniq.size == 1

    codecs
  end

  def current
    VIEWS.find { |v| v[:key] == view }
  end

  private

  def units
    return all_rows.chunk_while { |_, leg| leg["_leg"] == "b" }.to_a if view == "channels"

    all_rows.zip
  end

  def matching_units
    @matching_units ||= if filtered?
      needle = q.downcase

      units.select { |unit| unit.any? { |row| haystack(row).include?(needle) } }
    else
      units
    end
  end

  def haystack(row)
    SEARCH_FIELDS.map { |f| self.class.decode(row[f]) }.join(" ").downcase
  end

  LiveError = Struct.new(:message)

  def metrics
    @metrics ||= MetricsData.new(nil, server)
  end

  def live_count(metric)
    overview = live("overview")

    return nil unless overview.is_a?(Hash)

    value = case metric
    when "fs_calls" then overview["calls"]
    when "fs_channels" then overview["channels"]
    when "fs_sessions_per_sec" then status["sessions_per_sec"]
    end

    value&.to_i
  end

  # gateway_rows — `sofia xmlstatus` lists profiles, gateways and aliases in
  # one table; the Gateways tab shows profiles and gateways (aliases repeat a
  # profile under another name).
  def gateway_rows
    entries = Array(live("sofia")&.dig("entries"))

    entries.select { |e| %w[profile gateway].include?(e["kind"].to_s) }
  end

  # live — one cached read of a plugin route. Errors are stored as LiveError
  # (and not cached), so #error can surface them and the next poll retries.
  def live(route)
    return nil if @live[route].is_a?(LiveError)
    return @live[route] if @live.key?(route)

    @live[route] = Rails.cache.fetch(["fswapi", server.id, route], expires_in: LIVE_TTL) do
      @client.fswapi(route)
    end
  rescue Voodu::Client::Error => e
    @live[route] = LiveError.new(friendly(e))

    nil
  end

  def friendly(error)
    case error
    when Voodu::Client::NotFoundError
      "This controller has no FreeSWITCH route. Update voodu to v0.18.33 or later."
    when Voodu::Client::AuthError
      "The server's PAT cannot read plugin routes (#{error.message})."
    else
      error.message
    end
  end
end
