# frozen_string_literal: true

# Views::Metrics::Index — host CPU + memory cards with sparklines.
#
# Sparkline data is synthetic in M4 (the /stats endpoint is point-in-time).
# M5+ will persist a history table and feed the actual series in.
class Views::Metrics::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, stats: nil, error: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @stats          = stats
    @error          = error
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island
    ) do
      div(class: "mx-auto max-w-6xl px-6 py-6 flex flex-col gap-5") do
        header_block

        if @current_island.nil?
          render Components::UI::NoIslandState.new
        elsif @error
          render Components::UI::ErrorState.new(error: @error)
        else
          metric_cards
        end
      end
    end
  end

  private

  def header_block
    div(class: "flex items-baseline justify-between") do
      div(class: "flex flex-col gap-1") do
        h1(class: "text-2xl font-semibold text-voodu-text") { "Metrics" }
        p(class: "text-voodu-text-2 text-sm") { "Instantaneous host + pod stats." }
      end
      render(Components::UI::Button.new(tag: :a, variant: :ghost, size: :sm, href: metrics_path)) { "Refresh" }
    end
  end

  def metric_cards
    host = @stats&.dig("host") || {}

    div(class: "grid grid-cols-1 md:grid-cols-2 gap-4") do
      metric_card(
        label:  "Host CPU",
        value:  format_pct(host["cpu_percent"]),
        color:  "var(--voodu-accent)",
        series: synth_series(host["cpu_percent"] || 0)
      )
      metric_card(
        label:  "Host memory",
        value:  format_mem(host["mem_used_bytes"], host["mem_total_bytes"]),
        color:  "var(--voodu-blue)",
        series: synth_series(mem_pct(host))
      )
    end
  end

  def metric_card(label:, value:, color:, series:)
    render(Components::UI::Card.new) do
      div(class: "flex flex-col gap-3") do
        div(class: "flex items-baseline justify-between") do
          span(class: "text-[11px] uppercase tracking-wider text-voodu-muted") { label }
          span(class: "font-voodu-mono text-xl text-voodu-text") { value }
        end
        render Components::UI::Sparkline.new(data: series, color: color, height: 48)
      end
    end
  end

  def format_pct(v)
    return "—" if v.nil?

    "#{v.round(1)}%"
  end

  def format_mem(used, total)
    return "—" if used.nil? || total.nil? || total.zero?

    "#{(used.to_f / 1024 / 1024 / 1024).round(1)} / #{(total.to_f / 1024 / 1024 / 1024).round(1)} GB"
  end

  def mem_pct(host)
    used = host["mem_used_bytes"].to_f
    total = host["mem_total_bytes"].to_f
    return 0 if total.zero?

    (used / total) * 100
  end

  # synth_series — fabricates a smoothly-varying 30-point series
  # centered on the current value. Stable per render (seed = current
  # value rounded) so a refresh that returns the same value doesn't
  # redraw the sparkline shape completely.
  def synth_series(current)
    base = current.to_f.clamp(0, 100)
    seed = base.round
    rng = Random.new(seed * 17 + 3)
    (0..29).map do |i|
      jitter = rng.rand(-8.0..8.0)
      ((base + jitter) + Math.sin(i / 4.0) * 5).clamp(0, 100)
    end + [base]
  end
end
