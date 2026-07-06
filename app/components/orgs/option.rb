# frozen_string_literal: true

# Components::Orgs::Option — one row in the server form's org dropdown menu
# (a custom dropdown, not a native <select>, so it matches the rest of the UI).
# The stable id (org-opt-<uuid>) lets OrgsController replace/remove just this
# row via turbo_stream on rename/delete; data-org-id/name feed org_select's
# pick (sets the hidden input + trigger label). data-active rings the current
# selection. A trailing pencil opens the manager overlay straight into this
# org's edit form (org_manager#openAndEdit) — quick edit without hunting.
class Components::Orgs::Option < Components::Base
  def initialize(org:, selected: false)
    @org = org
    @selected = selected
  end

  def view_template
    div(
      id: "org-opt-#{@org.id}",
      data: {org_id: @org.id, org_name: @org.name, active: @selected.to_s},
      class: "group flex items-center min-h-[34px] text-[12.5px] hover:bg-voodu-hover " \
             "data-[active=true]:bg-voodu-accent-dim data-[active=true]:text-voodu-accent-2"
    ) do
      button(
        type: "button",
        data: {action: "click->org-select#pick click->dropdown#close"},
        class: "flex-1 min-w-0 flex items-center gap-2.5 px-3 py-2 text-left text-voodu-text"
      ) do
        render Icon::BuildingOffice2Outline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
        span(class: "truncate") { @org.name }
      end

      button(
        type: "button", "aria-label": "Edit #{@org.name}",
        # edit_org_id (not org_id) so it doesn't collide with the row's
        # selection data-attr that org_select scans.
        data: {action: "click->org-manager#openAndEdit click->dropdown#close", edit_org_id: @org.id},
        class: "shrink-0 inline-flex items-center justify-center w-8 h-8 mr-1 text-voodu-muted-2 " \
               "opacity-0 group-hover:opacity-100 hover:text-voodu-text focus:opacity-100"
      ) { render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5") }
    end
  end
end
