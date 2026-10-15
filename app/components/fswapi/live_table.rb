# frozen_string_literal: true

# Components::Fswapi::LiveTable — one live FreeSWITCH list (calls, channels,
# registrations or gateways), as the plugin returned it a few seconds ago.
#
# FreeSWITCH answers `show calls as json` with ~60 columns per row; the
# operator needs about six. Each view picks its columns here, by name, and
# reads them defensively: a FreeSWITCH version that drops a column renders a
# dash, not an error.
#
# The table scrolls sideways on a narrow screen rather than transposing: a
# call row is read across (from → to, state, how long), and a card per call
# breaks that reading.
class Components::Fswapi::LiveTable < Components::Base
  # Gateway / profile states from `sofia xmlstatus`. Red is for failures only
  # (CLAUDE.md palette rule); anything unknown stays neutral.
  STATE_TONES = {
    "RUNNING" => "var(--voodu-green)", "REGED" => "var(--voodu-green)", "UP" => "var(--voodu-green)",
    "NOREG" => "var(--voodu-green)",
    "TRYING" => "var(--voodu-amber)", "REGISTER" => "var(--voodu-amber)", "UNREGISTER" => "var(--voodu-amber)",
    "DOWN" => "var(--voodu-red)", "FAILED" => "var(--voodu-red)", "FAIL_WAIT" => "var(--voodu-red)",
    "EXPIRED" => "var(--voodu-red)", "UNREGED" => "var(--voodu-red)"
  }.freeze

  def initialize(view:, rows:, now: Time.current)
    @view = view
    @rows = rows
    @now = now
  end

  def view_template
    if @rows.empty?
      empty_state
    else
      div(class: "border border-voodu-border bg-voodu-surface overflow-x-auto") do
        table(class: "w-full min-w-[640px] text-[12.5px] border-collapse") do
          thead { tr { columns.each { |col| th_cell(col[:label]) } } }
          tbody do
            @rows.each do |row|
              call_header_row(row) if row["_leg"] == "a"
              body_row(row)
            end
          end
        end
      end
    end
  end

  private

  def columns
    case @view
    when "calls" then call_columns
    when "channels" then channel_columns
    when "registrations" then registration_columns
    else gateway_columns
    end
  end

  def call_columns
    [
      {label: "Duration", value: ->(r) { duration(r["created_epoch"]) }, mono: true},
      {label: "From", value: ->(r) { party(r["cid_num"], r["cid_name"]) }},
      {label: "To", value: ->(r) { party(decoded(r["dest"].presence || r["callee_num"]), r["callee_name"]) }},
      {label: "B-leg", value: ->(r) { decoded(r["b_dest"]).presence || r["b_cid_num"] }},
      {label: "State", value: ->(r) { r["callstate"] }},
      {label: "Direction", value: ->(r) { r["direction"] }}
    ]
  end

  # Channels arrive grouped by call (FswapiPageData.group_channels): each call
  # gets a summary row (call_header_row), then its legs — the A-leg, then the
  # B-legs bridged to it.
  def channel_columns
    [
      {label: "Leg", value: ->(r) { r["_leg"] }, leg: true},
      {label: "Duration", value: ->(r) { duration(r["created_epoch"]) }, mono: true},
      {label: "Channel", value: ->(r) { r["name"] }, mono: true},
      {label: "From", value: ->(r) { party(r["cid_num"], r["cid_name"]) }},
      {label: "Dest", value: ->(r) { decoded(r["dest"]) }},
      {label: "State", value: ->(r) { r["callstate"] }},
      {label: "App", value: ->(r) { r["application"] }},
      {label: "Codec", value: ->(r) { r["read_codec"] }, mono: true}
    ]
  end

  def registration_columns
    [
      {label: "User", value: ->(r) { [r["reg_user"], r["realm"]].compact_blank.join("@") }, mono: true},
      {label: "Network", value: ->(r) { network(r) }, mono: true},
      {label: "Contact", value: ->(r) { r["url"] }, mono: true},
      {label: "Expires", value: ->(r) { expires(r["expires"]) }, mono: true}
    ]
  end

  def gateway_columns
    [
      {label: "Kind", value: ->(r) { r["kind"] }},
      {label: "Name", value: ->(r) { r["name"] }, mono: true},
      {label: "Data", value: ->(r) { r["data"] }, mono: true},
      {label: "State", value: ->(r) { r["state"] }, state: true}
    ]
  end

  def th_cell(label)
    th(class: "px-3 h-8 text-left text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted border-b border-voodu-border whitespace-nowrap") do
      label
    end
  end

  def body_row(row)
    tr(class: row_class(row)) do
      columns.each do |col|
        text = col[:value].call(row).to_s.presence || "—"

        td(class: tokens("px-3 h-9 text-voodu-text-2 whitespace-nowrap max-w-[320px] truncate", col[:mono] && "font-voodu-mono text-[12px]")) do
          if col[:leg] then leg_cell(row)
          elsif col[:state] then state_cell(text)
          else plain(text)
          end
        end
      end
    end
  end

  # row_class — on the Channels tab the lines belong to the CALL, not the leg:
  # no line inside a call, and every other call on a tint, so a call's legs
  # read as one block. Other tabs keep a line per row.
  def row_class(row)
    return "border-b border-voodu-border last:border-b-0 hover:bg-voodu-hover" unless row["_leg"]

    call_tint(row)
  end

  def call_tint(row)
    row["_group"].to_i.odd? ? "bg-voodu-surface-2" : "bg-voodu-surface"
  end

  # Call states from `show channels` (callstate). Red stays for failures only.
  CALL_TONES = {
    "ACTIVE" => "var(--voodu-green)",
    "EARLY" => "var(--voodu-amber)", "RINGING" => "var(--voodu-amber)", "RING_WAIT" => "var(--voodu-amber)"
  }.freeze

  # call_header_row — one line per call, above its legs: how long, who called
  # whom, the call's state and how many legs it has. Spans the whole table.
  def call_header_row(lead)
    b = lead["_b"]
    state = lead["callstate"].to_s
    tone = CALL_TONES.fetch(state, "var(--voodu-muted)")

    tr(class: tokens(call_tint(lead), "border-t border-voodu-border first:border-t-0")) do
      td(colspan: columns.size, class: "px-3 pt-2.5 pb-1") do
        div(class: "flex items-center gap-3 text-[12.5px] whitespace-nowrap") do
          span(class: "inline-block w-2 h-2 rounded-full shrink-0", style: "background: #{tone};")
          span(class: "font-voodu-mono text-[12px] text-voodu-text") { duration(lead["created_epoch"]) || "—" }
          call_parties(lead, b)
          span(class: "font-voodu-mono text-[11px] text-voodu-text-2") { state.presence || "—" }
          transcode_badge(lead["_transcode"]) if lead["_transcode"]
          span(class: "ml-auto text-[11px] text-voodu-muted") { "#{lead["_legs"]} #{"leg".pluralize(lead["_legs"].to_i)}" }
        end
      end
    end
  end

  def call_parties(lead, b)
    span(class: "text-voodu-text truncate") do
      plain lead["cid_num"].presence || "—"
      span(class: "text-voodu-muted px-1.5") { "→" }
      plain decoded(lead["dest"]).presence || "—"

      # The B-leg's DESTINATION — where the call went out to. Its caller id is
      # the A-leg's, so showing that only repeated the number.
      if b
        span(class: "text-voodu-muted pl-2") { "bridged to " }
        plain decoded(b["dest"]).presence || b["cid_num"].to_s
      end
    end
  end

  # transcode_badge — the two legs read different codecs, so FreeSWITCH
  # converts the audio of this call both ways: CPU on every packet. Amber:
  # worth knowing, not a failure.
  def transcode_badge((a_codec, b_codec))
    span(
      title: "Transcoding: the legs use different codecs, so FreeSWITCH converts the audio (CPU).",
      class: "inline-flex items-center h-[18px] px-1.5 rounded-voodu-sm border border-voodu-amber text-voodu-amber font-voodu-mono text-[10.5px]"
    ) { "#{a_codec} → #{b_codec}" }
  end

  def decoded(value) = FswapiPageData.decode(value)

  # leg_cell — the call's header row is the parent and its legs the children:
  # "├ A-leg", then "└ B-leg" (├ while another leg follows). Words, not
  # letters: a lone "B" in a 20px chip was too easy to miss.
  def leg_cell(row)
    last = (row["_leg"] == "a") ? row["_legs"].to_i <= 1 : row["_last"]

    span(class: "inline-flex items-center gap-1.5 pl-2 text-[11.5px]") do
      span(class: "font-voodu-mono text-voodu-muted w-3 text-center", aria: {hidden: "true"}) { last ? "└" : "├" }

      if row["_leg"] == "b"
        span(class: "text-voodu-text-2") { "B-leg" }
      else
        span(class: "font-medium text-voodu-text") { "A-leg" }
      end
    end
  end

  def state_cell(text)
    tone = STATE_TONES[text.to_s.split.first.to_s.upcase] || "var(--voodu-muted)"

    span(class: "inline-flex items-center gap-1.5") do
      span(class: "inline-block w-1.5 h-1.5 rounded-full", style: "background: #{tone};")
      span(class: "font-voodu-mono text-[12px]") { text }
    end
  end

  def empty_state
    div(class: "border border-dashed border-voodu-border bg-voodu-surface px-4 py-10 text-center text-[12.5px] text-voodu-muted") do
      plain(EMPTY_TEXT.fetch(@view, "Nothing to show."))
    end
  end

  EMPTY_TEXT = {
    "calls" => "No active calls right now.",
    "channels" => "No open channels right now.",
    "registrations" => "No endpoint is registered.",
    "gateways" => "No SIP profile or gateway reported."
  }.freeze

  def party(number, name)
    number = number.to_s.strip
    name = name.to_s.strip

    return number if name.empty? || name == number

    number.empty? ? name : "#{number} (#{name})"
  end

  def duration(epoch)
    started = epoch.to_i

    return nil unless started.positive?

    secs = (@now.to_i - started).clamp(0, Float::INFINITY).to_i
    hours, rem = secs.divmod(3600)
    minutes, seconds = rem.divmod(60)

    hours.positive? ? Kernel.format("%d:%02d:%02d", hours, minutes, seconds) : Kernel.format("%d:%02d", minutes, seconds)
  end

  def network(row)
    ip = row["network_ip"].to_s

    return nil if ip.empty?

    [[ip, row["network_port"].presence].compact.join(":"), row["network_proto"].presence].compact.join(" ")
  end

  def expires(epoch)
    at = epoch.to_i

    return nil unless at.positive?

    left = at - @now.to_i

    left.positive? ? "in #{left}s" : "expired"
  end
end
