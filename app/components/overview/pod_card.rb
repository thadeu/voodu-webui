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

  # header_row — name + image stack on the left, status pill on the
  # right. The left stack is wrapped in an <a> so the operator can
  # tap anywhere on the title region to open the pod detail page
  # (mobile-mode equivalent of the desktop table's clickable name
  # column). Status pill is kept OUTSIDE the link to avoid nesting
  # interactives — and footer buttons (Logs/Restart) are siblings
  # for the same reason.
  def header_row
    div(class: "flex items-start gap-3") do
      a(
        href: helpers.pod_path(name: @pod[:name]),
        class: "flex flex-col gap-0.5 leading-tight min-w-0 flex-1 no-underline hover:text-voodu-accent-2 transition-colors"
      ) do
        span(class: "text-[14px] font-semibold text-voodu-text truncate") { @pod[:name] }
        span(class: "font-voodu-mono text-[11.5px] text-voodu-muted truncate") { @pod[:image] || "—" }
      end
      render Components::UI::StatusPill.new(status: @pod[:status])
    end
  end

  # 3-up grid: CPU / MEMORY / AGE. Restarts was removed alongside
  # the desktop table column — the value was synthetic (no wire
  # source) and operators reading a fake number is worse than the
  # column being absent.
  def stats_grid
    div(class: "grid grid-cols-2 gap-2.5") do
      cpu_stat
      memory_stat
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

  # restarts_stat removed — see stats_grid comment.

  def age_stat
    div(class: "flex flex-col gap-1") do
      stat_label("Age")
      span(class: "font-voodu-mono text-[13px] text-voodu-text-2") { @pod[:age] || "—" }
    end
  end

  def stat_label(text)
    span(class: "text-[10px] font-semibold uppercase tracking-wider text-voodu-muted") { text }
  end

  # footer_row — ports on the left, action cluster on the right.
  # Wide port lists (e.g. rabbitmq's 8 ports) would push the
  # actions off-screen; the ports span truncates with a tooltip
  # showing the full list. `min-w-0` on the span + `shrink-0` on
  # the actions container is the standard "let me truncate me but
  # not them" flex pattern.
  def footer_row
    div(class: "flex items-center gap-2 pt-2.5 border-t border-voodu-border min-w-0") do
      span(
        class: "font-voodu-mono text-[11px] text-voodu-muted truncate min-w-0 flex-1",
        title: ports_label
      ) { ports_label }
      div(class: "flex items-center gap-2 shrink-0") do
        open_pod_btn
        logs_btn
        restart_btn
      end
    end
  end

  def ports_label
    ports = @pod[:ports]
    ports.present? ? ":#{ports.join(',')}" : "—"
  end

  # open_pod_btn — icon-only affordance opening the pod detail page.
  # Sits to the LEFT of Logs/Restart as a clearer "view this pod"
  # signal than the (also-clickable) header_row title. Icon-only
  # keeps the footer from getting crowded on narrow viewports; the
  # cube icon matches the sidebar's Pods nav entry so the meaning
  # carries.
  def open_pod_btn
    a(
      href: helpers.pod_path(name: @pod[:name]),
      aria: { label: "Open pod" },
      title: "Open pod",
      class: "inline-flex items-center justify-center w-9 h-9 border border-voodu-border bg-voodu-surface-2 text-voodu-text-2 hover:bg-voodu-surface-3 hover:text-voodu-text"
    ) do
      render Icon::CubeOutline.new(class: "w-3.5 h-3.5")
    end
  end

  def logs_btn
    a(
      href: helpers.pod_logs_path(name: @pod[:name]),
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface-2 text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-3 hover:text-voodu-text"
    ) do
      render Icon::DocumentTextOutline.new(class: "w-3 h-3")
      span { "Logs" }
    end
  end

  def restart_btn
    return unless @pod[:status].in?(%i[running restarting])

    render(Components::UI::Confirmable.new(
      title:         "Restart pod",
      message:       %(Restart "#{@pod[:name]}"? The container will be stopped and recreated; in-flight traffic may be interrupted.),
      confirm_label: "Restart",
      icon:          :ArrowPathOutline,
      form: {
        action: helpers.restart_pod_path(name: @pod[:name]),
        method: :post
      },
      trigger: {
        title:        "Restart pod",
        "aria-label": "Restart #{@pod[:name]}",
        class:        "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface-2 text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-3 hover:text-voodu-text"
      }
    )) do
      render Icon::ArrowPathOutline.new(class: "w-3 h-3")
      span { "Restart" }
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
