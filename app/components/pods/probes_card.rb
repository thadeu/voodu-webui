# frozen_string_literal: true

# Components::Pods::ProbesCard — declared health-check definitions for
# the pod's container (liveness / readiness / startup), read from the
# manifest spec (`spec.probes`).
#
# Definitions ONLY — no live failure/recovery state. The controller
# doesn't expose probe phase over the PAT plane yet, so this card makes
# no claim about whether a probe is currently passing: no green/red
# dots, no "healthy/unhealthy". It answers "WHAT is checked and HOW
# often" so the operator doesn't have to crack open the manifest.
#
# Each probe renders a small uppercase divider label (the section style
# Thadeu prefers) followed by KvRows: the action target + the timing/
# threshold knobs. Absent knobs render a muted "default" instead of a
# fabricated number — the real defaults live server-side and we won't
# duplicate them here (drift risk if the k8s-parity defaults change).
class Components::Pods::ProbesCard < Components::Base
  # Timing/threshold knobs, in display order. Keys match the manifest
  # JSON (snake_case); all `omitempty` so any subset may be present.
  CONFIG_FIELDS = %w[
    period
    timeout
    initial_delay
    failure_threshold
    success_threshold
  ].freeze

  # probes: ordered Array of { kind:, spec: } from PodDetailData#probes.
  def initialize(probes:)
    @probes = probes
  end

  def view_template
    render Components::UI::SectionCard.new(title: "Probes") do
      @probes.each { |probe| probe_block(probe[:kind], probe[:spec]) }
    end
  end

  private

  def probe_block(kind, spec)
    div(class: "px-3.5 pt-3 pb-1.5 text-[11px] font-semibold uppercase tracking-wider text-voodu-muted") { kind }

    row("type") { plain action_summary(spec) }

    CONFIG_FIELDS.each do |key|
      val = spec[key]

      if val.present?
        row(key) { plain val.to_s }
      else
        row(key, dim: true) { plain "default" }
      end
    end
  end

  def row(key, **opts, &)
    render Components::UI::KvRow.new(key: key, **opts), &
  end

  # action_summary — one-line mono description of the probe action.
  # http_get → "GET /healthz:8080" (scheme prefix only when not http);
  # tcp_socket → "tcp :5432"; exec → "exec: sh -c …".
  def action_summary(spec)
    if (h = spec["http_get"]).is_a?(Hash)
      scheme = h["scheme"].to_s.downcase
      prefix = scheme.present? && scheme != "http" ? "#{scheme.upcase} " : ""

      "#{prefix}GET #{h["path"]}:#{h["port"]}"
    elsif (t = spec["tcp_socket"]).is_a?(Hash)
      "tcp :#{t["port"]}"
    elsif (e = spec["exec"]).is_a?(Hash)
      "exec: #{Array(e["command"]).join(" ")}"
    else
      "—"
    end
  end
end
