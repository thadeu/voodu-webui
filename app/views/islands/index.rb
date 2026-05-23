# frozen_string_literal: true

# Views::Islands::Index — list every registered island in a card grid.
# Each card shows name + endpoint + status pill + selector/remove.
class Views::Islands::Index < Views::Base
  def initialize(current_path:, islands:)
    @current_path = current_path
    @islands      = islands
  end

  def view_template
    render Components::Layouts::Dashboard.new(current_path: @current_path, islands: @islands) do
      div(class: "mx-auto max-w-4xl px-6 py-8 flex flex-col gap-6") do
        header_block

        if @islands.empty?
          empty_state
        else
          islands_grid
        end
      end
    end
  end

  private

  def header_block
    div(class: "flex items-center justify-between gap-4") do
      div(class: "flex flex-col gap-1") do
        h1(class: "text-2xl font-semibold text-voodu-text") { "Islands" }
        p(class: "text-voodu-text-2") { "Each island = one voodu controller this WebUI talks to." }
      end
      render(Components::UI::Button.new(tag: :a, variant: :primary, href: "/islands/new")) { "Add island" }
    end
  end

  def empty_state
    render Components::UI::Card.new do
      div(class: "py-8 flex flex-col items-center gap-3 text-center") do
        div(class: "h-10 w-10 rounded-voodu-md bg-voodu-accent-dim", aria: { hidden: "true" })
        p(class: "text-voodu-text-2") { "No islands registered yet." }
        p(class: "text-voodu-muted text-sm") { "Add the first one to start monitoring." }
        render(Components::UI::Button.new(tag: :a, variant: :primary, href: "/islands/new")) { "Add island" }
      end
    end
  end

  def islands_grid
    div(class: "grid grid-cols-1 md:grid-cols-2 gap-4") do
      @islands.each { |i| island_card(i) }
    end
  end

  def island_card(island)
    render(Components::UI::Card.new
            .with_header { card_header(island) }
            .with_footer { card_footer(island) }) do
      div(class: "flex flex-col gap-2 py-2") do
        meta_row("endpoint", island.endpoint)
        meta_row("registered", island.created_at.strftime("%Y-%m-%d %H:%M"))
      end
    end
  end

  def card_header(island)
    div(class: "flex items-center gap-3") do
      render Components::UI::StatusPill.new(status: island.status)
      span(class: "font-voodu-mono text-sm font-semibold text-voodu-text truncate") { island.name }
    end
  end

  def meta_row(label, value)
    div(class: "flex items-center gap-2 text-xs") do
      span(class: "text-voodu-muted w-20") { label }
      span(class: "font-voodu-mono text-voodu-text-2 truncate") { value }
    end
  end

  def card_footer(island)
    div(class: "flex items-center gap-2 justify-end") do
      form_tag("/islands/#{island.id}/select", method: :post, data: { turbo: false }) do
        button(
          type: "submit",
          class: "inline-flex items-center px-2.5 py-1 text-[11px] rounded-voodu-sm border border-voodu-border text-voodu-text-2 hover:bg-voodu-surface-2"
        ) { "Select" }
      end
      form_tag("/islands/#{island.id}", method: :delete, data: { turbo_confirm: "Remove #{island.name}?", turbo: false }) do
        button(
          type: "submit",
          class: "inline-flex items-center px-2.5 py-1 text-[11px] rounded-voodu-sm border border-voodu-red/30 text-voodu-red hover:bg-voodu-red-dim"
        ) { "Remove" }
      end
    end
  end

  def form_tag(action, method: :post, data: {}, &)
    form(action: action, method: (method == :get ? "get" : "post"), data: data) do
      # CSRF token + method override for non-GET/POST.
      input(type: "hidden", name: "authenticity_token", value: helpers.form_authenticity_token)
      input(type: "hidden", name: "_method", value: method.to_s) unless method.in?([:get, :post])
      yield if block_given?
    end
  end
end
