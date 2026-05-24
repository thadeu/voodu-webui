# frozen_string_literal: true

# Views::Islands::Index — server registry page.
#
# Tenant-less surface (no /:tenant_key prefix) — this is the meta
# screen where the operator manages WHICH servers the WebUI knows
# about. Add / edit / remove + see reachability at a glance.
#
# Layout pattern mirrors /pods (Components::Overview::PodsTable):
#
#   - Page header: H1 + count subline + "Add server" action
#   - Toolbar: status tabs (All / Online / Offline) + kv-filter input
#   - Desktop table: SERVER / STATUS / REGION / INFRA / AGE / ACTIONS
#   - Mobile list:   stacked cards (one per server) for < vmd
#
# Filtering, hover, the "no rows match" sentinel, and tab counts all
# carry the same conventions the pods page set, so muscle memory
# transfers between the two screens.
class Views::Islands::Index < Views::Base
  STATUS_TABS = [
    { id: :all,     label: "All",     status: nil,      color: nil },
    { id: :online,  label: "Online",  status: :online,  color: "var(--voodu-green)" },
    { id: :offline, label: "Offline", status: :offline, color: "var(--voodu-red)" }
  ].freeze

  def initialize(current_path:, islands:, active_tab: :all)
    @current_path = current_path
    @islands      = islands
    @active_tab   = active_tab
  end

  def view_template
    render Components::Layouts::Dashboard.new(current_path: @current_path, islands: @islands) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        page_header

        if @islands.empty?
          empty_state
        else
          server_section
        end
      end
    end
  end

  private

  def page_header
    div(class: "flex flex-wrap items-end justify-between gap-3 vmd:gap-4") do
      div(class: "min-w-0") do
        h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight") { "Servers" }
        page_sub
      end
      add_server_btn
    end
  end

  # page_sub — "● 2 online · ● 1 offline".
  # Same look as /pods's "● N running · ● M restarting · ● K stopped".
  def page_sub
    counts = status_counts
    div(class: "flex flex-wrap items-center gap-2.5 mt-1 text-[12.5px] text-voodu-muted") do
      stat_bit("var(--voodu-green)", "online",  counts[:online])
      dot_sep
      stat_bit("var(--voodu-red)",   "offline", counts[:offline])
    end
  end

  def stat_bit(color, label, count)
    span(class: "inline-flex items-center gap-1.5") do
      span(class: "inline-block w-1.5 h-1.5 rounded-full", style: "background: #{color};")
      span(class: "font-voodu-mono text-voodu-text-2") { count.to_s }
      span { label }
    end
  end

  def add_server_btn
    a(
      href: helpers.new_island_path,
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-white text-[12.5px] font-medium hover:bg-voodu-accent-2 shrink-0"
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span { "Add server" }
    end
  end

  # empty_state — onboarding-ish callout when the registry is empty.
  # In practice the operator rarely lands here in this state — the
  # DashboardController#redirect_to_default bounces them to
  # /islands/new — but the state still exists for the case where
  # someone navigates here AFTER removing their last server.
  def empty_state
    div(class: "py-12 flex flex-col items-center gap-3 text-center border border-voodu-border bg-voodu-surface") do
      div(class: "h-10 w-10 rounded-voodu-md bg-voodu-accent-dim border border-voodu-accent-line flex items-center justify-center text-voodu-accent-2") do
        render Icon::ServerStackOutline.new(class: "w-5 h-5")
      end
      p(class: "text-voodu-text-2 text-[13px]") { "No servers registered yet." }
      p(class: "text-voodu-muted text-[12px]") { "Add the first one to start monitoring." }
      div(class: "pt-1") { add_server_btn }
    end
  end

  # server_section — wraps both the desktop table and the mobile
  # card list in a single kv-filter scope, identical to the pods
  # surface. Each row carries a `data-key` blob so the controller
  # filters BOTH layouts in lockstep.
  def server_section
    section(class: "flex flex-col gap-3", data: { controller: "kv-filter" }) do
      toolbar
      desktop_table
      mobile_list
    end
  end

  # toolbar — same shape as PodsTable#toolbar: stacked vertically
  # below vmd, side-by-side above. Tabs scroll horizontally on
  # narrow viewports so they're never pushed off-screen.
  def toolbar
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2.5 vmd:gap-3") do
      tabs
      filter_input
    end
  end

  def tabs
    div(class: "flex items-center gap-1 overflow-x-auto -mx-3.5 px-3.5 vmd:mx-0 vmd:px-0 vmd:overflow-visible") do
      STATUS_TABS.each { |tab| tab_button(tab) }
    end
  end

  def tab_button(tab)
    active = tab[:id] == @active_tab
    count = tab_count(tab)
    href = tab[:id] == :all ? "?" : "?status=#{tab[:id]}"

    a(
      href: href,
      class: tokens(
        "inline-flex items-center gap-2 px-2.5 h-7 text-[12px] rounded-voodu-sm border transition-colors shrink-0",
        active ? "border-voodu-border bg-voodu-surface text-voodu-text" : "border-transparent text-voodu-text-2 hover:bg-voodu-surface hover:text-voodu-text"
      )
    ) do
      if tab[:color]
        span(class: "inline-block w-1.5 h-1.5 rounded-full", style: "background: #{tab[:color]};")
      end
      span { tab[:label] }
      span(class: "font-voodu-mono text-[10.5px] text-voodu-muted") { count.to_s }
    end
  end

  def tab_count(tab)
    return @islands.size if tab[:id] == :all

    @islands.count { |i| i.status == tab[:status] }
  end

  def filter_input
    div(class: "flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface w-full vmd:flex-1 vmd:max-w-[420px] text-voodu-muted") do
      render Icon::FunnelOutline.new(class: "w-3 h-3 shrink-0")
      input(
        type: "search",
        name: "filter",
        placeholder: "filter by name, endpoint, region or infra…",
        data: {
          kv_filter_target: "input",
          action: "input->kv-filter#filter"
        },
        class: "flex-1 bg-transparent border-0 outline-none text-[12px] text-voodu-text placeholder:text-voodu-muted-2"
      )
    end
  end

  # desktop_table — six columns, 1100px+ only. Below vmd we render
  # mobile_list instead (same kv-filter rows). Column widths are
  # implicit (browser-allocated); the actions cell is `text-right`
  # so the buttons cluster on the right edge.
  def desktop_table
    div(class: "hidden vmd:block border border-voodu-border overflow-hidden bg-voodu-surface") do
      table(class: "w-full text-[12.5px] border-collapse") do
        thead(class: "bg-voodu-bg-2") do
          tr do
            %w[server status region infra age].each do |col|
              th(class: "text-left px-3 py-2 text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted border-b border-voodu-border") { col }
            end
            th(class: "text-right px-3 py-2 text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted border-b border-voodu-border") { "actions" }
          end
        end
        tbody do
          islands_for_active_tab.each { |i| desktop_row(i) }
          tr(hidden: true, data: { kv_filter_target: "empty" }) do
            td(colspan: 6, class: "px-3 py-8 text-center text-voodu-muted text-[12px]") { "no servers match the filter." }
          end
        end
      end
    end
  end

  def desktop_row(island)
    tr(
      class: "border-b border-voodu-border last:border-b-0 hover:bg-voodu-surface-2 transition-colors",
      data: {
        kv_filter_target: "row",
        key: search_blob(island)
      }
    ) do
      td(class: "px-3 py-2.5") { server_cell(island) }
      td(class: "px-3 py-2.5") { render Components::UI::StatusPill.new(status: island.status || :stopped) }
      td(class: "px-3 py-2.5 text-[11.5px] text-voodu-text-2") { meta_value(island.region) }
      td(class: "px-3 py-2.5 text-[11.5px] text-voodu-text-2") { meta_value(island.infra) }
      td(class: "px-3 py-2.5 font-voodu-mono text-[11px] text-voodu-muted") { age_label(island) }
      td(class: "px-3 py-2.5 text-right") { row_actions(island) }
    end
  end

  # server_cell — compound identity column. Two-tier display:
  #   name (bold, sans)
  #   endpoint (mono muted, truncated)
  # Clicking either line opens the island's overview. Same shape
  # as Components::Overview::PodsTable#pod_cell so the eye lands
  # on the same spot when bouncing between /pods and /islands.
  def server_cell(island)
    a(
      href: helpers.tenant_root_path(tenant_key: island.key),
      class: "flex items-baseline gap-2.5 min-w-0 hover:text-voodu-accent-2 transition-colors"
    ) do
      span(class: "text-[13px] font-semibold text-voodu-text whitespace-nowrap") { island.name }
      span(class: "font-voodu-mono text-[11.5px] text-voodu-muted truncate min-w-0") { island.endpoint }
    end
  end

  def meta_value(v)
    return "—" if v.blank? || v == "—"

    v
  end

  def age_label(island)
    secs = (Time.current - island.created_at).to_i
    return "#{secs}s" if secs < 60
    return "#{secs / 60}m" if secs < 3_600
    return "#{secs / 3_600}h" if secs < 86_400

    "#{secs / 86_400}d"
  end

  # mobile_list — stacked cards under vmd. Mirrors PodCard shape:
  # header (name + endpoint + status pill), meta row (region · infra
  # · age), action row.
  def mobile_list
    div(class: "vmd:hidden flex flex-col gap-2") do
      islands_for_active_tab.each do |island|
        div(
          data: {
            kv_filter_target: "row",
            key: search_blob(island)
          }
        ) { mobile_card(island) }
      end
      div(
        hidden: true,
        data: { kv_filter_target: "empty" },
        class: "py-8 text-center text-voodu-muted text-[12px] border border-voodu-border bg-voodu-surface"
      ) { "no servers match the filter." }
    end
  end

  def mobile_card(island)
    div(class: "flex flex-col gap-3 p-3 border border-voodu-border bg-voodu-surface") do
      # Header: name+endpoint clickable (opens island), status pill right.
      div(class: "flex items-start gap-3") do
        a(
          href: helpers.tenant_root_path(tenant_key: island.key),
          class: "flex flex-col gap-0.5 leading-tight min-w-0 flex-1 no-underline hover:text-voodu-accent-2 transition-colors"
        ) do
          span(class: "text-[14px] font-semibold text-voodu-text truncate") { island.name }
          span(class: "font-voodu-mono text-[11.5px] text-voodu-muted truncate") { island.endpoint }
        end
        render Components::UI::StatusPill.new(status: island.status || :stopped)
      end

      # Meta strip: region · infra · age. Hidden segments collapse
      # cleanly if both region+infra are blank.
      mobile_meta(island)

      # Footer: actions cluster.
      div(class: "flex items-center gap-2 pt-2.5 border-t border-voodu-border") do
        div(class: "flex-1")
        row_actions(island)
      end
    end
  end

  def mobile_meta(island)
    region = meta_value(island.region)
    infra  = meta_value(island.infra)
    age    = age_label(island)
    parts  = [region, infra].reject { |v| v == "—" }
    parts << "age #{age}"

    div(class: "flex flex-wrap items-center gap-1.5 text-[11px] text-voodu-muted") do
      parts.each_with_index do |p, i|
        span(class: "font-voodu-mono text-voodu-text-2") { p }
        if i < parts.size - 1
          span(class: "inline-block w-[3px] h-[3px] rounded-full bg-voodu-border-2", "aria-hidden": "true")
        end
      end
    end
  end

  def row_actions(island)
    div(class: "inline-flex items-center gap-1.5") do
      open_btn(island)
      edit_btn(island)
      remove_form(island)
    end
  end

  def open_btn(island)
    a(
      href: helpers.tenant_root_path(tenant_key: island.key),
      title: "Open overview",
      "aria-label": "Open #{island.name}",
      class: action_btn_classes
    ) do
      render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "Open" }
    end
  end

  def edit_btn(island)
    a(
      href: helpers.edit_island_path(island),
      title: "Edit server",
      "aria-label": "Edit #{island.name}",
      class: action_btn_classes
    ) do
      render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "Edit" }
    end
  end

  def remove_form(island)
    form(
      action: helpers.island_path(island), method: "post",
      data: { turbo_confirm: "Remove #{island.name}?", turbo: false },
      class: "inline-flex"
    ) do
      input(type: "hidden", name: "authenticity_token", value: helpers.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")
      button(
        type: "submit",
        title: "Remove server",
        "aria-label": "Remove #{island.name}",
        class: "inline-flex items-center gap-1.5 px-2.5 h-8 border border-voodu-red/30 text-voodu-red text-[12px] font-medium hover:bg-voodu-red-dim"
      ) do
        render Icon::TrashOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "Remove" }
      end
    end
  end

  def action_btn_classes
    "inline-flex items-center gap-1.5 px-2.5 h-8 border border-voodu-border bg-voodu-surface-2 text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-3 hover:text-voodu-text"
  end

  # ── data shaping ─────────────────────────────────────────────

  def islands_for_active_tab
    return @islands if @active_tab == :all

    target = STATUS_TABS.find { |t| t[:id] == @active_tab }&.dig(:status)
    return @islands if target.nil?

    @islands.select { |i| i.status == target }
  end

  def status_counts
    {
      online:  @islands.count { |i| i.status == :online },
      offline: @islands.count { |i| i.status == :offline }
    }
  end

  def search_blob(island)
    [island.name, island.endpoint, island.region, island.infra].compact.join(" ").downcase
  end

  def dot_sep
    span(class: "inline-block w-[3px] h-[3px] rounded-full bg-voodu-border-2", "aria-hidden": "true")
  end
end
