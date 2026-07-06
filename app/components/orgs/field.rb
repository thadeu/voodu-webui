# frozen_string_literal: true

# Components::Orgs::Field — the org picker in the server-registration form. A
# CUSTOM dropdown (the project's dropdown controller, matching every other
# picker) rather than a native <select>: a trigger button + a menu of org rows
# + a hidden input that carries the chosen org_id on submit. A "New org" button
# opens the manager overlay (org_manager_controller#open).
#
# Realtime: the menu is `#org-options`, so OrgsController appends / replaces /
# removes a single row (org-opt-<uuid>) via turbo_stream on create / rename /
# delete — the operator's current selection (the hidden input) is untouched.
# The org_select controller wires a row click → hidden input + trigger label,
# and toggles the empty-state as rows come and go.
#
# Rendered INSIDE the add-server <form>; the "New org" trigger reaches
# org_manager because that controller wraps both the form and the overlay.
class Components::Orgs::Field < Components::Base
  def initialize(orgs:, selected_id: nil)
    @orgs = orgs
    @selected_id = selected_id
  end

  def view_template
    div(class: "flex flex-col gap-1.5", data: {controller: "org-select"}) do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { "Org" }

      div(class: "flex items-center gap-2") do
        picker
        new_org_button
      end

      div(class: "text-[11.5px] text-voodu-muted") do
        plain(@orgs.empty? ? "No orgs yet — create one to group this server." : "Every server belongs to an org.")
      end
    end
  end

  private

  # picker — the dropdown: hidden input (the submitted value) + trigger + menu.
  # `dropdown` handles open/close + viewport flip; `org-select` (the parent)
  # handles selection.
  def picker
    div(class: "relative flex-1 min-w-0", data: {controller: "dropdown"}) do
      input(
        type: "hidden", name: "server[org_id]", value: @selected_id,
        data: {org_select_target: "input"}
      )
      trigger
      menu
    end
  end

  def trigger
    button(
      type: "button",
      data: {action: "click->dropdown#toggle"},
      class: "w-full min-w-0 flex items-center gap-2 h-9 px-2.5 border border-voodu-border bg-voodu-surface " \
             "text-[13px] text-voodu-text hover:border-voodu-border-2 focus:outline-none focus:border-voodu-accent-line"
    ) do
      span(
        data: {org_select_target: "label"},
        class: tokens("flex-1 min-w-0 truncate text-left", selected_org ? "text-voodu-text" : "text-voodu-muted-2")
      ) { selected_org&.name || "Select an org…" }
      render Icon::ChevronDownOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
    end
  end

  def menu
    div(
      id: "org-options",
      hidden: true,
      data: {dropdown_target: "menu"},
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-full w-max max-w-[280px] max-h-[280px] " \
             "overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
    ) do
      # Empty-state row: shown only while there are no org rows. org_select
      # hides it the moment one is appended (create) and shows it again if the
      # last one is removed (delete).
      div(
        data: {org_select_target: "empty"},
        hidden: @orgs.any?,
        class: "px-3 py-2 text-[12px] text-voodu-muted"
      ) { "No orgs yet — use “New org”." }

      @orgs.each { |org| render Components::Orgs::Option.new(org: org, selected: org.id == @selected_id) }
    end
  end

  def new_org_button
    button(
      type: "button",
      data: {action: "org-manager#open"},
      class: "shrink-0 inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface " \
             "text-voodu-text-2 text-[12.5px] hover:border-voodu-accent-line hover:bg-voodu-accent-dim hover:text-voodu-accent-2"
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "New org" }
    end
  end

  def selected_org
    return @selected_org if defined?(@selected_org)

    @selected_org = @selected_id.present? ? @orgs.find { |o| o.id == @selected_id } : nil
  end
end
