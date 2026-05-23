# frozen_string_literal: true

# Views::Dashboard::Index — root "/" overview.
#
# Three-state pattern matching the rest:
#   - no island        → NoIslandState
#   - controller error → ErrorState
#   - happy            → 4 summary cards
#
# The cards show host CPU + memory sparklines, pod count, and a
# rolling "controller status" badge. M5+ can add more cards (last
# deploy, alerts) when the upstream data exists.
class Views::Dashboard::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, stats: nil, pods: [], error: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @stats          = stats
    @pods           = pods
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
          overview_cards
        end
      end
    end
  end

  private

  def header_block
    div(class: "flex items-baseline justify-between") do
      div(class: "flex flex-col gap-1") do
        h1(class: "text-2xl font-semibold text-voodu-text") { "Overview" }
        if @current_island
          p(class: "text-voodu-text-2 text-sm") do
            plain "Live snapshot of "
            span(class: "font-voodu-mono text-voodu-accent-2") { @current_island.name }
          end
        end
      end
    end
  end

  def overview_cards
    host = @stats&.dig("host") || {}
    running_count = @pods.count { |p| p["running"] }

    div(class: "grid grid-cols-2 md:grid-cols-4 gap-4") do
      stat_card("Running pods", running_count.to_s, "of #{@pods.size}", "var(--voodu-green)")
      stat_card("Host CPU",     pct(host["cpu_percent"]), "instantaneous", "var(--voodu-accent)")
      stat_card("Host memory",  mem(host["mem_used_bytes"], host["mem_total_bytes"]), "in use", "var(--voodu-blue)")
      stat_card("Island",       @current_island.name, @current_island.host, "var(--voodu-text)", mono: true)
    end
  end

  def stat_card(label, value, sub, color, mono: false)
    render(Components::UI::Card.new) do
      div(class: "flex flex-col gap-2") do
        span(class: "text-[10.5px] uppercase tracking-wider text-voodu-muted") { label }
        span(
          class: tokens("text-xl", mono ? "font-voodu-mono" : "font-semibold"),
          style: "color: #{color};"
        ) { value }
        span(class: "text-[11px] text-voodu-muted") { sub }
      end
    end
  end

  def pct(v)
    return "—" if v.nil?

    "#{v.round(1)}%"
  end

  def mem(used, total)
    return "—" if used.nil? || total.nil? || total.zero?

    "#{(used.to_f / 1024**3).round(1)}/#{(total.to_f / 1024**3).round(1)} GB"
  end
end
