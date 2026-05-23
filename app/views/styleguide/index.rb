# frozen_string_literal: true

# Views::Styleguide::Index — visual inventory of every primitive in
# Components::UI. Mounted at /styleguide. Acts as both:
#
#   1. A QA surface — render every component in every variant, glance
#      across to spot drift after a refactor.
#   2. The canonical "look this up" for a developer about to add a
#      new screen — copy a block, paste, tweak.
class Views::Styleguide::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island
    ) do
      div(class: "mx-auto max-w-5xl px-6 py-8 flex flex-col gap-10") do
        page_header
        section_buttons
        section_badges
        section_status
        section_cards
        section_forms
        section_misc
      end
    end
  end

  private

  def page_header
    div(class: "flex flex-col gap-1") do
      h1(class: "text-2xl font-semibold text-voodu-text") { "Styleguide" }
      p(class: "text-voodu-text-2") do
        "Every primitive in Components::UI, rendered side-by-side."
      end
    end
  end

  def section(title)
    div(class: "flex flex-col gap-3") do
      h2(class: "text-sm font-semibold uppercase tracking-wider text-voodu-muted") { title }
      div(class: "p-4 rounded-voodu-md border border-voodu-border bg-voodu-surface") do
        yield
      end
    end
  end

  def section_buttons
    section("Buttons") do
      div(class: "flex flex-col gap-4") do
        div(class: "flex flex-wrap items-center gap-3") do
          %i[primary secondary ghost danger inversed].each do |v|
            render Components::UI::Button.new(variant: v) { v.to_s }
          end
        end
        div(class: "flex flex-wrap items-center gap-3") do
          %i[sm md lg].each { |sz| render Components::UI::Button.new(size: sz) { "size #{sz}" } }
        end
      end
    end
  end

  def section_badges
    section("Badges") do
      div(class: "flex flex-wrap items-center gap-2") do
        %i[neutral accent success warning danger info].each do |v|
          render Components::UI::Badge.new(variant: v) { v.to_s }
        end
        render Components::UI::Badge.new(variant: :success, dot: true) { "with dot" }
      end
    end
  end

  def section_status
    section("Status (Dot + Pill + Spinner + MiniBar)") do
      div(class: "flex flex-col gap-5") do
        div(class: "flex items-center gap-6") do
          %i[online running restarting offline stopped pending].each do |status|
            div(class: "flex items-center gap-2") do
              render Components::UI::StatusDot.new(status: status)
              span(class: "text-xs text-voodu-text-2") { status.to_s }
            end
          end
        end
        div(class: "flex flex-wrap items-center gap-2") do
          %i[running online restarting offline stopped pending].each do |status|
            render Components::UI::StatusPill.new(status: status)
          end
        end
        div(class: "flex items-center gap-3") do
          render Components::UI::Spinner.new
          render Components::UI::Spinner.new(size: 20, color: "var(--voodu-accent)")
        end
        div(class: "flex flex-col gap-2") do
          [10, 45, 78, 99].each do |v|
            div(class: "flex items-center gap-3") do
              render Components::UI::MiniBar.new(value: v)
              span(class: "font-voodu-mono text-xs text-voodu-text-2") { "#{v}%" }
            end
          end
        end
      end
    end
  end

  def section_cards
    section("Cards") do
      div(class: "grid grid-cols-1 md:grid-cols-3 gap-4") do
        %i[default flat accent].each do |v|
          render(Components::UI::Card.new(variant: v)
                  .with_header { span(class: "text-sm font-semibold") { v.to_s } }) do
            p(class: "text-voodu-text-2") { "Variant: #{v}" }
          end
        end
      end
    end
  end

  def section_forms
    section("Forms") do
      div(class: "max-w-md flex flex-col gap-4") do
        render Components::Form::Group.new(label: "Island name", hint: "Free-form label.") do
          render Components::Form::Input.new(placeholder: "production-sao-paulo")
        end
        render Components::Form::Group.new(label: "Destination", hint: "Port optional (defaults to 8687).") do
          render Components::Form::Input.new(mono: true, placeholder: "203.0.113.10")
        end
        render Components::Form::Group.new(label: "PAT") do
          render Components::Form::Input.new(mono: true, placeholder: "pat_a3F9bZ2k7Qm9pNvX4tCfH5d8yL2eRw")
        end
      end
    end
  end

  def section_misc
    section("Misc (Kbd + Avatar)") do
      div(class: "flex flex-col gap-5") do
        div(class: "flex items-center gap-2 text-voodu-text-2") do
          span { "press" }
          render Components::UI::Kbd.new { "⌘" }
          render Components::UI::Kbd.new { "K" }
          span { "to search" }
        end
        div(class: "flex items-center gap-4") do
          %i[sm md lg xl].each { |sz| render Components::UI::Avatar.new(name: "voodu", size: sz) }
        end
      end
    end
  end
end
