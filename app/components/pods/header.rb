# frozen_string_literal: true

# Components::Pods::Header — pod detail page header.
#
# Layout (mirrors the inspiration's PodDetailPage header):
#
#   ← All pods
#
#   clowk-vd-docs.35a3                          [View logs] [Restart pod]
#   ● Running · kind deployment · scope clowk-vd · clowk-vd-docs:latest · ip 172.18.0.5 · age 7m
#
# Title is mono with the scope half muted and the .replica_id suffix
# in a lighter weight so the eye lands on the resource_name.
class Components::Pods::Header < Components::Base
  # drawer: true → embedded inside Components::UI::Drawer (Metrics
  # page's "Open pod" peek). Hides "All pods" back_link — the
  # drawer's own X / open-in-new-tab affordances cover the close
  # and the "I want the full page" intents.
  def initialize(data:, drawer: false)
    @data   = data
    @drawer = drawer
  end

  def view_template
    div(class: "flex flex-col gap-3") do
      back_link unless @drawer
      # Stack on mobile, side-by-side at vmd+. The previous
      # `flex flex-wrap` collapsed under pressure: `flex-1 min-w-0`
      # on identity_block let the title shrink to ~30px and break
      # character-by-character (mono pod name has no spaces, so
      # `break-all` cascades to one char per line). Column-on-mobile
      # gives the title its full row, then the action buttons land
      # on the next row at natural width.
      div(class: "flex flex-col vmd:flex-row vmd:flex-wrap vmd:items-start gap-3 vmd:gap-4") do
        identity_block
        action_buttons
      end
    end
  end

  private

  def back_link
    a(
      href: pods_path,
      class: "inline-flex items-center gap-1.5 self-start text-[12.5px] text-voodu-text-2 hover:text-voodu-text"
    ) do
      render Icon::ArrowLeftOutline.new(class: "w-3.5 h-3.5")
      span { "All pods" }
    end
  end

  def identity_block
    div(class: "flex-1 min-w-0") do
      h1(
        class: "font-voodu-mono text-[22px] vmd:text-[24px] font-semibold tracking-tight break-all m-0",
        style: "color: var(--voodu-text);"
      ) do
        if @data.scope
          span(class: "text-voodu-muted font-medium") { @data.scope }
          span(class: "text-voodu-muted font-medium") { "-" }
        end
        plain @data.resource_name.to_s
        if @data.replica_id
          span(class: "text-voodu-muted font-normal") { ".#{@data.replica_id}" }
        end
      end

      meta_chips
    end
  end

  def meta_chips
    net = primary_network
    ip  = net && net["ip_address"]

    div(class: "flex flex-wrap items-center gap-1.5 mt-3") do
      render Components::UI::StatusPill.new(status: @data.status_sym)

      labeled_chip("kind",  @data.kind.to_s)
      labeled_chip("scope", @data.scope.to_s)
      render Components::UI::Chip.new(mono: true) { plain @data.image.to_s.presence || "—" }
      labeled_chip("ip", ip.to_s) if ip
      restarts_chip if @data.restarts.positive?
      labeled_chip("age", @data.age_label)
    end
  end

  def labeled_chip(label, value)
    render Components::UI::Chip.new do
      span(class: "text-voodu-muted") { label }
      span(class: "text-voodu-text-2 font-voodu-mono ml-1") { value }
    end
  end

  def restarts_chip
    render Components::UI::Chip.new do
      span(class: "font-voodu-mono text-voodu-amber") { @data.restarts.to_s }
      span(class: "text-voodu-muted ml-1") { "restarts" }
    end
  end

  def primary_network
    raw_nets = @data.raw&.dig("networks")
    return nil unless raw_nets.is_a?(Hash) && raw_nets.any?

    raw_nets.values.first
  end

  # action_buttons — View logs + View metrics + Restart on the full
  # page; only Restart inside the drawer (the operator opened the
  # drawer from Metrics — "View logs" would be redundant with the
  # separate Logs drawer already living in the same toolbar, and
  # "View metrics" would just bounce them back to the page they came
  # from).
  def action_buttons
    div(class: "flex items-center gap-2 shrink-0") do
      unless @drawer
        view_logs_btn
        view_metrics_btn
      end
      restart_btn
    end
  end

  # view_logs_btn — opens the pod's logs viewer inside a right-side
  # Drawer so the operator can peek without losing the pod context.
  # Same wiring Metrics page uses for its "Logs" action (see
  # Views::Metrics::Index#pod_actions): src points at the embed
  # variant, open_url at the full page so cmd-click / middle-click
  # still gets a real navigation. Drawer is wider than the Pod peek
  # (40vw default) because log lines are long.
  def view_logs_btn
    name = @data.name

    render(Components::UI::Drawer.new(
      title:     "Logs · #{name}",
      src:       "#{pod_logs_path(name: name)}?embed=1",
      open_url:  pod_logs_path(name: name),
      width:     "70vw",
      # Logs are content-heavy (long lines, dense JSON dumps);
      # let the operator drag the drawer up to 85vw when they
      # need to read a wide payload without scrolling sideways.
      max_width: "85vw",
      trigger_attrs: {
        class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      }
    )) do
      render Icon::DocumentTextOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "View logs" }
    end
  end

  # view_metrics_btn — jumps to /metrics filtered to THIS pod's
  # scope. Plain anchor (no drawer): the operator asked for the
  # full metrics surface, not a peek; cmd-click still opens in a
  # new tab as expected. Mirrors view_logs_btn's secondary-button
  # styling so the action row reads as a single visual group.
  def view_metrics_btn
    a(
      href:  metrics_path(scope_kind: "pod", scope_id: @data.name),
      title: "View metrics",
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::ChartBarOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "View metrics" }
    end
  end

  def restart_btn
    name = @data.name

    render(Components::UI::Confirmable.new(
      title:         "Restart pod",
      message:       %(Restart "#{name}"? The container will be stopped and recreated; in-flight traffic may be interrupted.),
      confirm_label: "Restart pod",
      icon:          :ArrowPathOutline,
      form: {
        action: restart_pod_path(name: name),
        method: :post
      },
      trigger: {
        title:        "Restart pod",
        "aria-label": "Restart #{name}",
        class:        "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-white text-[12.5px] font-medium hover:bg-voodu-accent-2"
      }
    )) do
      render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "Restart pod" }
    end
  end
end
