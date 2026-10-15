# frozen_string_literal: true

# Fswapi::Format — how a FreeSWITCH row reads, shared by the /fswapi page
# (Components::Fswapi::LiveTable) and the dashboard table panel
# (DataTable::FswapiSource), so a call never reads one way on the page and
# another on a dashboard.
#
# FreeSWITCH answers `show calls/channels as json` with ~60 columns per row;
# each view keeps about six, by name, read defensively: a FreeSWITCH version
# that drops a column renders a dash, not an error.
module Fswapi::Format
  module_function

  # columns — [{field:, label:, mono:, value: ->(row, now)}] for a view.
  def columns(view)
    case view.to_s
    when "calls" then CALL_COLUMNS
    when "channels" then CHANNEL_COLUMNS
    when "registrations" then REGISTRATION_COLUMNS
    else GATEWAY_COLUMNS
    end
  end

  CALL_COLUMNS = [
    {field: "duration", label: "Duration", mono: true, value: ->(r, now) { duration(r["created_epoch"], now) }},
    {field: "from", label: "From", value: ->(r, _) { party(r["cid_num"], r["cid_name"]) }},
    {field: "to", label: "To", value: ->(r, _) { party(decode(r["dest"].presence || r["callee_num"]), r["callee_name"]) }},
    {field: "b_leg", label: "B-leg", value: ->(r, _) { decode(r["b_dest"]).presence || r["b_cid_num"] }},
    {field: "state", label: "State", value: ->(r, _) { r["callstate"] }},
    {field: "direction", label: "Direction", value: ->(r, _) { r["direction"] }}
  ].freeze

  CHANNEL_COLUMNS = [
    {field: "duration", label: "Duration", mono: true, value: ->(r, now) { duration(r["created_epoch"], now) }},
    {field: "channel", label: "Channel", mono: true, value: ->(r, _) { r["name"] }},
    {field: "from", label: "From", value: ->(r, _) { party(r["cid_num"], r["cid_name"]) }},
    {field: "dest", label: "Dest", value: ->(r, _) { decode(r["dest"]) }},
    {field: "state", label: "State", value: ->(r, _) { r["callstate"] }},
    {field: "app", label: "App", value: ->(r, _) { r["application"] }},
    {field: "codec", label: "Codec", mono: true, value: ->(r, _) { r["read_codec"] }}
  ].freeze

  REGISTRATION_COLUMNS = [
    {field: "user", label: "User", mono: true, value: ->(r, _) { [r["reg_user"], r["realm"]].compact_blank.join("@") }},
    {field: "network", label: "Network", mono: true, value: ->(r, _) { network(r) }},
    {field: "contact", label: "Contact", mono: true, value: ->(r, _) { r["url"] }},
    {field: "expires", label: "Expires", mono: true, value: ->(r, now) { expires(r["expires"], now) }}
  ].freeze

  GATEWAY_COLUMNS = [
    {field: "kind", label: "Kind", value: ->(r, _) { r["kind"] }},
    {field: "name", label: "Name", mono: true, value: ->(r, _) { r["name"] }},
    {field: "data", label: "Data", mono: true, value: ->(r, _) { r["data"] }},
    {field: "state", label: "State", mono: true, state: true, value: ->(r, _) { r["state"] }}
  ].freeze

  # decode — FreeSWITCH URL-encodes some dial-string characters
  # (`0656%23552…` is `0656#552…`). ASCII only: a stray byte stays as it was.
  def decode(value)
    value.to_s.gsub(/%(\h\h)/) { ((h = ::Regexp.last_match(1).hex) < 0x80) ? h.chr : ::Regexp.last_match(0) }
  end

  def party(number, name)
    number = number.to_s.strip
    name = name.to_s.strip

    return number if name.empty? || name == number

    number.empty? ? name : "#{number} (#{name})"
  end

  def duration(epoch, now = Time.current)
    started = epoch.to_i

    return nil unless started.positive?

    secs = [now.to_i - started, 0].max
    hours, rem = secs.divmod(3600)
    minutes, seconds = rem.divmod(60)

    hours.positive? ? Kernel.format("%d:%02d:%02d", hours, minutes, seconds) : Kernel.format("%d:%02d", minutes, seconds)
  end

  def network(row)
    ip = row["network_ip"].to_s

    return nil if ip.empty?

    [[ip, row["network_port"].presence].compact.join(":"), row["network_proto"].presence].compact.join(" ")
  end

  def expires(epoch, now = Time.current)
    at = epoch.to_i

    return nil unless at.positive?

    left = at - now.to_i

    left.positive? ? "in #{left}s" : "expired"
  end
end
