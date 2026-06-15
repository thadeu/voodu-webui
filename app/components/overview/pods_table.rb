# frozen_string_literal: true

# Components::Overview::PodsTable — the dense pod grid on the Overview
# screen.
#
# Three sections stacked:
#
#   1. Section heading — "Pods · 14 of 14"
#   2. Toolbar         — status filter tabs (All / Running / Restarting
#                        / Stopped) + free-text name/image filter input
#   3. Table           — 7 columns (pod, status, cpu, memory, restarts,
#                        age, ports). Hover lifts the row background.
#
# `pods` is the prepared shape (see Overview::Data — each pod is a Hash
# with :name, :image, :status (sym), :cpu_pct, :mem_used_mb,
# :mem_total_mb, :restarts, :age, :ports).
class Components::Overview::PodsTable < Components::Base
  STATUS_TABS = [
    { id: :all,        label: "All",        status: nil,         color: nil },
    { id: :running,    label: "Running",    status: :running,    color: "var(--voodu-green)" },
    { id: :restarting, label: "Restarting", status: :restarting, color: "var(--voodu-amber)" },
    { id: :stopped,    label: "Stopped",    status: :stopped,    color: "var(--voodu-muted)" }
  ].freeze

  # show_heading — Overview embeds this table as one of multiple
  # sections, so it wants the H2 "Pods" label as a section break.
  # The dedicated /pods page already shows an H1 "Pods" via its
  # own page_header — passing `show_heading: false` suppresses
  # the redundant H2 there.
  def initialize(pods:, total:, active_tab: :all, show_heading: true)
    @pods         = pods
    @total        = total
    @active_tab   = active_tab
    @show_heading = show_heading
  end

  def view_template
    # Whole section is one `kv-filter` scope — the filter input
    # walks the rows in BOTH desktop_table (<tr>) AND mobile_list
    # (<article>). Each row carries `data-key` (the searchable blob:
    # name + scope + resource + image + kind + status) so the
    # controller doesn't have to know about table vs card layout.
    section(class: "flex flex-col gap-3", data: { controller: "kv-filter" }) do
      heading if @show_heading
      toolbar
      desktop_table
      mobile_list
    end
  end

  private

  def heading
    div(class: "flex items-center gap-2") do
      h2(class: "text-base font-semibold text-voodu-text") { "Pods" }
      span(class: "font-voodu-mono text-[11px] text-voodu-muted") { "#{@pods.size} of #{@total}" }
    end
  end

  # toolbar — tabs + filter input.
  # On mobile (< vmd) the two stack vertically so neither overflows
  # the viewport. Tabs also become horizontally scrollable on very
  # narrow widths so the four status buttons stay reachable instead
  # of being pushed off-screen by the filter input.
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
        # shrink-0 keeps each tab readable even when the row is
        # tight — they overflow horizontally instead of squeezing
        # their labels (see tabs's overflow-x-auto on mobile).
        "inline-flex items-center gap-2 px-2.5 h-7 text-[12px] rounded-voodu-sm border transition-colors shrink-0",
        active ? "border-voodu-border bg-voodu-surface text-voodu-text" : "border-transparent text-voodu-text-2 hover:bg-voodu-surface hover:text-voodu-text"
      )
    ) do
      if tab[:color]
        span(
          class: "inline-block w-1.5 h-1.5 rounded-full",
          style: "background: #{tab[:color]};"
        )
      end
      span { tab[:label] }
      span(class: "font-voodu-mono text-[10.5px] text-voodu-muted") { count.to_s }
    end
  end

  def tab_count(tab)
    return @total if tab[:id] == :all

    @pods.count { |p| p[:status] == tab[:status] }
  end

  def filter_input
    # On mobile (stacked layout) the input takes full width — no
    # max-w cap, since the tabs row above already used the width
    # budget. On vmd+ the cap returns so the input doesn't grow
    # wider than its useful reading length.
    div(class: "flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface w-full vmd:flex-1 vmd:max-w-[420px] text-voodu-muted") do
      render Icon::FunnelOutline.new(class: "w-3 h-3 shrink-0")
      input(
        type: "search",
        name: "filter",
        placeholder: "filter by name, scope or image…",
        data: {
          kv_filter_target: "input",
          action: "input->kv-filter#filter"
        },
        class: "flex-1 bg-transparent border-0 outline-none text-[12px] text-voodu-text placeholder:text-voodu-muted-2"
      )
    end
  end

  # desktop_table — full table for 1100px+ widths. The 7 columns assume
  # at least ~720px of room to read; below that, mobile_list takes over.
  def desktop_table
    div(class: "hidden vmd:block border border-voodu-border overflow-hidden bg-voodu-surface") do
      table(class: "w-full text-[12.5px] border-collapse") do
        thead(class: "bg-voodu-surface") do
          tr do
            %w[pod status cpu memory age ports].each do |col|
              th(class: "text-left px-3 py-2 text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted border-b border-voodu-border") { col }
            end
          end
        end
        tbody do
          if @pods.empty?
            empty_row("no pods match.")
          else
            @pods.each { |pod| pod_row(pod) }
            # Hidden by default — kv-filter unhides it when the search
            # input zeroes every other row. Lives inside <tbody> so the
            # colspan spans the table.
            tr(hidden: true, data: { kv_filter_target: "empty" }) do
              td(colspan: 6, class: "px-3 py-8 text-center text-voodu-muted text-[12px]") { "no pods match the filter." }
            end
          end
        end
      end
    end
  end

  # mobile_list — stack of PodCards for < 1100px widths. Replaces the
  # table entirely on narrow viewports rather than horizontally
  # scrolling, which scales much better as the pod count grows.
  def mobile_list
    div(class: "vmd:hidden flex flex-col gap-2") do
      if @pods.empty?
        div(class: "py-8 text-center text-voodu-muted text-[12px] border border-voodu-border bg-voodu-surface") { "no pods match." }
      else
        @pods.each do |pod|
          # Wrap each card in a data-kv-filter-target row so the mobile
          # list filters in lockstep with the desktop table.
          div(
            data: {
              kv_filter_target: "row",
              key: pod_search_blob(pod),
              value: pod[:image].to_s.downcase
            }
          ) do
            render Components::Overview::PodCard.new(pod: pod)
          end
        end
      end
    end
  end

  def empty_row(msg)
    tr do
      td(colspan: 6, class: "px-3 py-8 text-center text-voodu-muted text-[12px]") { msg }
    end
  end

  # pod_row — each <tr> exposes `data-key` (the searchable blob,
  # already lowercased) so the kv-filter controller can do plain
  # `.includes(query)` without re-walking the cells.
  def pod_row(pod)
    tr(
      class: "border-b border-voodu-border last:border-b-0 hover:bg-voodu-surface-2 transition-colors",
      data: {
        kv_filter_target: "row",
        key: pod_search_blob(pod),
        value: pod[:image].to_s.downcase
      }
    ) do
      pod_cell(pod)
      status_cell(pod)
      cpu_cell(pod)
      memory_cell(pod)
      age_cell(pod)
      ports_cell(pod)
    end
  end

  # pod_search_blob — combined haystack for the kv-filter controller.
  # Anything a "find me that pod" query might reasonably match goes in:
  # full name, scope, resource, image, kind, status.
  def pod_search_blob(pod)
    [
      pod[:name], pod[:scope], pod[:resource_name],
      pod[:image], pod[:kind], pod[:status]
    ].compact.join(" ").downcase
  end

  # pod_cell — compound identity column. Two-tier display:
  #
  #   scope/resource_name.replica_id      ← clickable, scope muted
  #   image (mono muted, truncated)
  #
  # Clicking either line opens the pod detail page.
  def pod_cell(pod)
    td(class: "px-3 py-2.5") do
      a(
        href: pod_path(name: pod[:name]),
        class: "flex items-baseline gap-2.5 min-w-0 hover:text-voodu-link-2 transition-colors"
      ) do
        span(class: "font-voodu-mono text-[13px] font-semibold text-voodu-link whitespace-nowrap") do
          if pod[:scope]
            span(class: "text-voodu-muted font-medium") { pod[:scope] }
            span(class: "text-voodu-muted font-medium") { "/" }
          end
          plain pod[:resource_name] || pod[:name]
          if pod[:replica_id]
            span(class: "text-voodu-muted font-normal") { ".#{pod[:replica_id]}" }
          end
        end
        span(class: "font-voodu-mono text-[11.5px] text-voodu-muted truncate min-w-0") { pod[:image] || "—" }
      end
    end
  end

  def status_cell(pod)
    td(class: "px-3 py-2.5") do
      render Components::UI::StatusPill.new(status: pod[:status])
    end
  end

  def cpu_cell(pod)
    td(class: "px-3 py-2.5") do
      bar_cell(value: pod[:cpu_pct], unit: "%", color: "var(--voodu-purple)", max: 100)
    end
  end

  def memory_cell(pod)
    td(class: "px-3 py-2.5") do
      used = pod[:mem_used_mb]
      total = pod[:mem_total_mb]

      div(class: "flex flex-col gap-1") do
        div(class: "flex items-center gap-2") do
          span(class: "font-voodu-mono text-[11px] text-voodu-text") { format_mem_pair(used, total) }
          render Components::UI::MiniBar.new(value: used || 0, max: total || 1, color: "var(--voodu-blue)") if used && total
        end
      end
    end
  end

  # restarts_cell removed — the column was a fabricated number (the
  # PAT plane's /pods doesn't expose a restart count today; was a
  # mock). Bring it back once the controller surfaces a real count
  # per replica.

  def age_cell(pod)
    td(class: "px-3 py-2.5 font-voodu-mono text-[11px] text-voodu-muted") { pod[:age] || "—" }
  end

  # ports_cell — tight column. Wide port lists (e.g. [80, 443, 8080,
  # 9090]) ellipsis instead of pushing the action / age columns
  # around. Hover tooltip shows the full list.
  def ports_cell(pod)
    ports = pod[:ports]
    label = ports.present? ? ports.join(",") : "—"

    td(class: "px-3 py-2.5 font-voodu-mono text-[11px] text-voodu-text-2 max-w-[140px]") do
      span(class: "block truncate whitespace-nowrap", title: label) { label }
    end
  end

  def bar_cell(value:, unit:, color:, max:)
    div(class: "flex items-center gap-2") do
      label = value.nil? ? "0.0#{unit}" : "#{'%.1f' % value}#{unit}"
      span(class: "font-voodu-mono text-[11px] text-voodu-text w-12") { label }
      render Components::UI::MiniBar.new(value: value || 0, max: max, color: color)
    end
  end

  def format_mem_pair(used, total)
    return "—" if used.nil? || total.nil?

    "#{used} / #{total} MB"
  end
end
