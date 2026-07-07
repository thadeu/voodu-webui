# frozen_string_literal: true

# Components::Orgs::Panel — the re-renderable body of the org manager overlay
# (target id `org-manager-panel`). Master-detail, like the dashboards manager:
# a rail of orgs on the LEFT, an editor pane on the RIGHT. The rail's "+" (and
# the empty state) select the New-org form; a rail row selects that org's edit
# form. Only one detail pane (`data-org-pane`) shows at a time.
#
# OrgsController replaces this whole node via turbo_stream on every CRUD action,
# optionally carrying:
#   - create_org — a rejected create (New pane active, errors shown)
#   - edit_org   — a rejected update (that org's edit pane active, errors shown)
#   - error      — a top-level message (e.g. delete blocked: org owns servers)
#
# The overlay is portaled to <body> (escaping the modal's transform), so rail
# selection rides org_manager's DELEGATED click listener (data-org-select /
# data-org-new), not data-action (which wouldn't resolve off-subtree).
class Components::Orgs::Panel < Components::Base
  def initialize(orgs:, create_org: nil, edit_org: nil, error: nil)
    @orgs = orgs
    @create_org = create_org || Org.new
    @edit_org = edit_org
    @error = error
  end

  def view_template
    div(id: "org-manager-panel", class: "flex flex-col vmd:flex-row min-h-[340px] vmd:h-[380px]") do
      rail
      detail
    end
  end

  private

  # ── rail (left) ────────────────────────────────────────────────────

  def rail
    div(class: "shrink-0 vmd:w-[200px] border-b vmd:border-b-0 vmd:border-r border-voodu-border bg-voodu-surface flex flex-col") do
      div(class: "flex items-center justify-between gap-2 px-3 pt-3 pb-2") do
        span(class: "text-[11px] font-medium text-voodu-text-2 uppercase tracking-[0.06em]") { "Orgs" }
        new_button
      end

      div(id: "orgs-list", class: "flex vmd:flex-col gap-1 px-2.5 pb-2.5 overflow-auto scrollbar-hidden") do
        if @orgs.empty?
          span(class: "text-[11.5px] text-voodu-muted px-1 py-2") { "No orgs yet — use +." }
        else
          @orgs.each { |org| rail_item(org) }
        end
      end
    end
  end

  # new_button — the square "+" that reveals the New-org pane (data-org-new;
  # delegated because the overlay is portaled).
  def new_button
    button(
      type: "button", "aria-label": "New org",
      data: {org_new: true, tooltip: "New org"},
      class: "inline-flex items-center justify-center w-7 h-7 shrink-0 border border-voodu-border bg-voodu-surface text-voodu-muted " \
             "hover:border-voodu-accent-line hover:bg-voodu-accent-dim hover:text-voodu-accent-2 transition-colors"
    ) { render Icon::PlusOutline.new(class: "w-4 h-4") }
  end

  # rail_item — selects this org's edit pane. Active (data-active) when it's the
  # one being edited; the org_manager controller re-syncs active on selection.
  def rail_item(org)
    active = @edit_org && @edit_org.id == org.id

    button(
      type: "button",
      id: "org-rail-#{org.id}",
      data: {org_select: org.id, active: active.to_s},
      class: tokens(
        "group flex items-center gap-2.5 px-2.5 py-2 shrink-0 min-w-[150px] vmd:min-w-0 text-left border vmd:border-y-0 vmd:border-r-0 vmd:border-l-2",
        "border-voodu-border-2 vmd:border-l-transparent hover:bg-voodu-surface-2",
        "data-[active=true]:border-voodu-accent-line data-[active=true]:bg-voodu-accent-dim vmd:data-[active=true]:border-l-voodu-accent"
      )
    ) do
      render Icon::BuildingOffice2Outline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted group-data-[active=true]:text-voodu-accent-2")
      div(class: "min-w-0") do
        span(class: "block text-[12.5px] truncate text-voodu-text group-data-[active=true]:text-voodu-accent-2 group-data-[active=true]:font-medium") { org.name }

        if org.description.present?
          span(class: "block text-[11px] text-voodu-muted truncate") { org.description }
        end
      end
    end
  end

  # ── detail (right) ─────────────────────────────────────────────────

  # detail — the editor pane: one New-org form + one edit form per org, only
  # the active one shown (org_manager toggles `hidden` on data-org-pane). The
  # active pane on (re)render is server-driven: edit_org → that org's; else New.
  def detail
    div(class: "flex-1 min-w-0 flex flex-col p-4 gap-3 overflow-auto") do
      top_error if @error.present?
      create_pane
      @orgs.each { |org| edit_pane(org) }
    end
  end

  def top_error
    div(class: "px-3 py-2 border border-voodu-red/45 bg-voodu-red-dim text-[12px] text-voodu-red") { @error }
  end

  def create_pane
    div(data: {org_pane: "new"}, hidden: @edit_org.present?, class: "flex flex-col gap-3") do
      pane_header("New org")

      form(action: orgs_path, method: "post", class: "flex flex-col gap-2") do
        csrf
        text_input("org[name]", @create_org.name, "Name — e.g. Production")
        field_error(@create_org, :name)
        text_input("org[description]", @create_org.description, "Description (optional)")
        tz_field(@create_org, detect: true)

        button(type: "submit", class: primary_btn) do
          render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
          span { "Create org" }
        end
      end
    end
  end

  def edit_pane(org)
    editing = @edit_org && @edit_org.id == org.id
    data = editing ? @edit_org : org

    div(data: {org_pane: org.id}, hidden: !editing, class: "flex flex-col gap-3") do
      div(class: "flex items-center justify-between gap-2") do
        pane_header("Edit org")
        delete_form(org)
      end

      form(action: org_path(org), method: "post", class: "flex flex-col gap-2") do
        csrf
        input(type: "hidden", name: "_method", value: "patch")
        text_input("org[name]", data.name, "Name")
        field_error(data, :name)
        text_input("org[description]", data.description, "Description (optional)")
        tz_field(data, detect: false)

        button(type: "submit", class: primary_btn) do
          render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
          span { "Save changes" }
        end
      end
    end
  end

  def pane_header(label)
    span(class: "text-[11px] font-medium text-voodu-text-2 uppercase tracking-[0.06em]") { label }
  end

  def delete_form(org)
    form(action: org_path(org), method: "post", class: "shrink-0", data: {turbo_confirm: "Delete org #{org.name}?"}) do
      csrf
      input(type: "hidden", name: "_method", value: "delete")
      button(
        type: "submit", "aria-label": "Delete org",
        class: "inline-flex items-center gap-1.5 px-2.5 h-7 border border-voodu-border bg-voodu-surface text-voodu-muted text-[11.5px] hover:text-voodu-red hover:border-voodu-red/40"
      ) do
        render Icon::TrashOutline.new(class: "w-3.5 h-3.5")
        span { "Delete" }
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────

  def csrf
    input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
  end

  def text_input(name, value, placeholder)
    input(
      type: "text", name: name, value: value, placeholder: placeholder,
      autocomplete: "off", spellcheck: "false",
      class: "w-full h-9 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
    )
  end

  # tz_field — IANA timezone for the org (mono input + hint). `detect: true`
  # on the New-org pane tags the input so org_manager fills it with the
  # browser's detected zone when empty — so a fresh org never silently
  # renders in UTC (the invisible-gap this whole feature closes). Edit panes
  # show the stored value verbatim (blank = inherit) without auto-filling.
  def tz_field(record, detect:)
    div(class: "flex flex-col gap-1") do
      input(
        type: "text", name: "org[timezone]", value: record.timezone,
        placeholder: "Timezone — e.g. America/Sao_Paulo",
        autocomplete: "off", spellcheck: "false",
        data: (detect ? {org_tz_detect: true} : {}),
        class: "w-full h-9 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] font-voodu-mono placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
      )
      field_error(record, :timezone)
      span(class: "text-[11px] text-voodu-muted-2") { "Renders every chart & timestamp for this org's servers. Blank uses UTC." }
    end
  end

  def field_error(record, attr)
    msg = record.errors[attr].first
    return unless msg

    div(class: "text-[11px] text-voodu-red") { msg }
  end

  def primary_btn
    "self-start inline-flex items-center gap-1.5 px-3 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent/20"
  end
end
