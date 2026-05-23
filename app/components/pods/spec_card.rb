# frozen_string_literal: true

# Components::Pods::SpecCard — top-level container facts.
#
# Bypass rendering: each line is a key/value pair pulled straight
# from the pod JSON. No invented labels, no human-friendly aliases —
# what the API returns is what shows up.
#
# A handful of fields get tiny formatting helpers (StatusPill for
# state.status, datetime formatter for the timestamps, copy buttons
# for the long opaque id). Everything else is dumped as-is.
class Components::Pods::SpecCard < Components::Base
  def initialize(pod:)
    @pod = pod
  end

  def view_template
    render Components::UI::SectionCard.new(title: "Spec") do
      row("image")          { plain @pod["image"].to_s.presence || "—" }
      row("id", copy: id, copy_value: id) { id_value }
      row("restart_policy") { plain @pod["restart_policy"].to_s.presence || "—" }
      row("working_dir")    { plain @pod["working_dir"].to_s.presence || "—" }
      row("entrypoint")     { plain join_str(@pod["entrypoint"]) }
      row("command")        { plain join_str(@pod["command"]) }
      row("state.status")   { render Components::UI::StatusPill.new(status: state_status_sym) }
      row("created_at")     { datetime_with_rel(@pod["created_at"]) }
      row("state.started_at",  dim: !started?)  { started?  ? datetime_with_rel(state_dig("started_at"))  : plain("never") }
      row("state.finished_at", dim: !finished?) { finished? ? datetime_with_rel(state_dig("finished_at")) : plain("never") }
    end
  end

  private

  def row(key, **opts, &)
    render Components::UI::KvRow.new(key: key, **opts), &
  end

  def id
    @id ||= @pod["id"].to_s
  end

  def id_value
    if id.length > 24
      span { plain id[0, 24] }
      span(class: "text-voodu-muted") { plain "…" }
    else
      plain(id.presence || "—")
    end
  end

  def state_dig(key)
    @pod.dig("state", key)
  end

  def state_status_sym
    s = state_dig("status").to_s.downcase
    return :running if s == "running"
    return :restarting if s.include?("restart")
    return :stopped if s == "stopped" || s == "exited"

    :stopped
  end

  def started?
    s = state_dig("started_at").to_s
    s.present? && !s.start_with?("0001-")
  end

  def finished?
    s = state_dig("finished_at").to_s
    s.present? && !s.start_with?("0001-")
  end

  def datetime_with_rel(iso)
    iso = iso.to_s
    if iso.blank? || iso.start_with?("0001-")
      plain "—"
      return
    end

    plain format_datetime(iso)
    span(class: "text-voodu-muted") { plain " · #{relative_time(iso)}" }
  end

  def format_datetime(iso)
    iso.sub("T", " ").sub(/\.\d+/, "").sub("Z", " UTC")
  end

  def relative_time(iso)
    t = Time.zone.parse(iso)
    secs = (Time.current - t).to_i.abs
    case secs
    when 0..59         then "#{secs}s ago"
    when 60..3599      then "#{secs / 60}m ago"
    when 3600..86_399  then "#{secs / 3600}h ago"
    else                    "#{secs / 86_400}d ago"
    end
  rescue ArgumentError, TypeError
    "—"
  end

  def join_str(val)
    case val
    when Array  then val.join(" ").presence || "—"
    when String then val.presence || "—"
    else             "—"
    end
  end
end
