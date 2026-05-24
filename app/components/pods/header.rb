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
  def initialize(data:)
    @data = data
  end

  def view_template
    div(class: "flex flex-col gap-3") do
      back_link
      div(class: "flex flex-wrap items-start gap-4") do
        identity_block
        action_buttons
      end
    end
  end

  private

  def back_link
    a(
      href: helpers.pods_path,
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

  def action_buttons
    div(class: "flex items-center gap-2 shrink-0") do
      view_logs_btn
      restart_btn
    end
  end

  def view_logs_btn
    a(
      href: helpers.pod_logs_path(name: @data.name),
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::DocumentTextOutline.new(class: "w-3.5 h-3.5")
      span { "View logs" }
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
        action: helpers.restart_pod_path(name: name),
        method: :post
      },
      trigger: {
        title:        "Restart pod",
        "aria-label": "Restart #{name}",
        class:        "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-white text-[12.5px] font-medium hover:bg-voodu-accent-2"
      }
    )) do
      render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
      span { "Restart pod" }
    end
  end
end
