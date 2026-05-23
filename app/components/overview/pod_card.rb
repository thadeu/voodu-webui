# frozen_string_literal: true

# Components::Overview::PodCard — mobile card variant of one pod row.
# Renders below 1100px (vd-md) where the 7-column table would clip.
#
# Anatomy (mirrors the inspiration's PodCard exactly):
#
#   nginx-edge                              [Running]
#   nginx:1.27-alpine
#   ──────────────────────────────────────────────────
#   CPU       MEMORY    RESTARTS    AGE
#   4.2%      86/256MB  0           12d 4h
#   ▓░░       ▓▓░░
#   ──────────────────────────────────────────────────
#   :80,443                         [Logs] [Restart]
class Components::Overview::PodCard < Components::Base
  def initialize(pod:)
    @pod = pod
  end

  def view_template
    li(class: "flex flex-col gap-3 p-3 border border-voodu-border bg-voodu-surface list-none") do
      header_row
      stats_grid
      footer_row
    end
  end

  private

  def header_row
    div(class: "flex items-start gap-3") do
      div(class: "flex flex-col gap-0.5 leading-tight min-w-0 flex-1") do
        span(class: "text-[14px] font-semibold text-voodu-text truncate") { @pod[:name] }
        span(class: "font-voodu-mono text-[11.5px] text-voodu-muted truncate") { @pod[:image] || "—" }
      end
      render Components::UI::StatusPill.new(status: @pod[:status])
    end
  end

  # 2×2 grid: CPU / MEMORY / RESTARTS / AGE — same layout the
  # inspiration's `ss.cardStats` produces with `grid-template-columns: 1fr 1fr`.
  def stats_grid
    div(class: "grid grid-cols-2 gap-2.5") do
      cpu_stat
      memory_stat
      restarts_stat
      age_stat
    end
  end

  def cpu_stat
    div(class: "flex flex-col gap-1 min-w-0") do
      stat_label("CPU")
      span(
        class: "font-voodu-mono text-[13px]",
        style: "color: #{muted? ? 'var(--voodu-muted-2)' : 'var(--voodu-text)'};"
      ) do
        plain cpu_value
        span(class: "text-voodu-muted") { "%" }
      end
      render Components::UI::MiniBar.new(
        value: @pod[:cpu_pct] || 0, max: 100,
        color: cpu_color, width: 200, height: 3
      )
    end
  end

  def memory_stat
    div(class: "flex flex-col gap-1 min-w-0") do
      stat_label("Memory")
      span(
        class: "font-voodu-mono text-[13px]",
        style: "color: #{muted? ? 'var(--voodu-muted-2)' : 'var(--voodu-text)'};"
      ) do
        if mem_used && mem_total
          plain mem_used.to_s
          span(class: "text-voodu-muted") { " / #{mem_total}MB" }
        else
          plain "—"
        end
      end
      if mem_used && mem_total
        render Components::UI::MiniBar.new(
          value: mem_used, max: mem_total,
          color: mem_color, width: 200, height: 3
        )
      end
    end
  end

  def restarts_stat
    div(class: "flex flex-col gap-1") do
      stat_label("Restarts")
      r = @pod[:restarts] || 0
      span(
        class: "font-voodu-mono text-[13px]",
        style: "color: #{r.positive? ? 'var(--voodu-amber)' : 'var(--voodu-text)'};"
      ) { r.to_s }
    end
  end

  def age_stat
    div(class: "flex flex-col gap-1") do
      stat_label("Age")
      span(class: "font-voodu-mono text-[13px] text-voodu-text-2") { @pod[:age] || "—" }
    end
  end

  def stat_label(text)
    span(class: "text-[10px] font-semibold uppercase tracking-wider text-voodu-muted") { text }
  end

  def footer_row
    div(class: "flex items-center gap-2 pt-2.5 border-t border-voodu-border") do
      span(class: "font-voodu-mono text-[11px] text-voodu-muted") do
        ports = @pod[:ports]
        ports.present? ? ":#{ports.join(',')}" : "—"
      end
      div(class: "flex-1")
      logs_btn
      restart_btn
    end
  end

  def logs_btn
    a(
      href: "/logs/#{CGI.escape(@pod[:name])}",
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface-2 text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-3 hover:text-voodu-text"
    ) do
      render Icon::DocumentTextOutline.new(class: "w-3 h-3")
      span { "Logs" }
    end
  end

  def restart_btn
    return unless @pod[:status].in?(%i[running restarting])

    form(
      action: "/pods/#{CGI.escape(@pod[:name])}/restart", method: "post",
      data: { turbo_confirm: "Restart #{@pod[:name]}?", turbo: false },
      class: "inline-flex"
    ) do
      input(type: "hidden", name: "authenticity_token", value: helpers.form_authenticity_token)
      button(
        type: "submit",
        class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface-2 text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-3 hover:text-voodu-text"
      ) do
        render Icon::ArrowPathOutline.new(class: "w-3 h-3")
        span { "Restart" }
      end
    end
  end

  # ── Helpers (mirror inspiration's color thresholds) ──

  def muted?
    @pod[:status] == :stopped || @pod[:status] == :restarting
  end

  def cpu_value
    v = @pod[:cpu_pct]
    v.nil? ? "0.0" : "%.1f" % v
  end

  def cpu_color
    v = @pod[:cpu_pct] || 0
    return "var(--voodu-red)"   if v > 90
    return "var(--voodu-amber)" if v > 70

    "var(--voodu-accent)"
  end

  def mem_used  = @pod[:mem_used_mb]
  def mem_total = @pod[:mem_total_mb]

  def mem_color
    return "var(--voodu-blue)" unless mem_used && mem_total
    return "var(--voodu-amber)" if (mem_used.to_f / mem_total) > 0.8

    "var(--voodu-blue)"
  end
end
