# frozen_string_literal: true

# Components::Orgs::Overlay — the org-manager overlay: a backdrop + a light
# centered card wrapping Components::Orgs::Panel. Hidden until the "New org"
# trigger opens it (org_manager_controller toggles the `overlay` target).
#
# Rendered as a SIBLING of the add-server <form> (both inside the
# org-manager controller element) so its create/edit/delete <form>s are NOT
# nested inside the add-server form — invalid HTML otherwise. z-[80] sits
# above the add-server modal (z-[70]).
class Components::Orgs::Overlay < Components::Base
  def initialize(orgs:)
    @orgs = orgs
  end

  def view_template
    div(data: {org_manager_target: "overlay"}, hidden: true, class: "fixed inset-0 z-[80] flex items-center justify-center p-4") do
      div(
        "aria-hidden": "true",
        data: {org_backdrop: true},
        class: "absolute inset-0 bg-black/55 backdrop-blur-[3px]"
      )

      div(
        role: "dialog", "aria-modal": "true", "aria-label": "Manage orgs",
        class: "relative w-[min(640px,calc(100vw-32px))] max-h-[calc(100vh-64px)] flex flex-col bg-voodu-surface-2 border border-voodu-border-2 shadow-[0_28px_56px_rgba(0,0,0,0.65)]"
      ) do
        header(class: "flex items-center gap-2.5 px-4 py-3 border-b border-voodu-border bg-voodu-surface") do
          span(class: "inline-flex items-center justify-center w-[26px] h-[26px] bg-voodu-accent-dim border border-voodu-accent-line text-voodu-accent-2 shrink-0") do
            render Icon::BuildingOffice2Outline.new(class: "w-3.5 h-3.5")
          end

          div(class: "min-w-0 flex-1") do
            h2(class: "m-0 text-[14px] font-semibold text-voodu-text leading-tight") { "Manage orgs" }
            div(class: "text-[11px] text-voodu-muted mt-0.5") { "Group your servers — an org owns N servers" }
          end

          button(
            type: "button", "aria-label": "Close",
            data: {org_close: true},
            class: "inline-flex items-center justify-center w-7 h-7 border border-voodu-border bg-voodu-surface text-voodu-muted hover:text-voodu-text shrink-0"
          ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
        end

        div(class: "overflow-auto min-h-0") do
          render Components::Orgs::Panel.new(orgs: @orgs)
        end
      end
    end
  end
end
