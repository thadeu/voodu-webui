# frozen_string_literal: true

# Components::UI::WorkspaceTabs — browser-like tabs inside one page, with a
# "+" that opens the page fresh in a new tab. Built for /hep3 (watch two
# readers side by side without losing either), generic on purpose.
#
# URL first: the active tab is its URL (`?ws=<id>&…` — not `tab`, which the
# breadcrumb already reads as a page section), the server renders it.
# Only the LIST of tabs lives client-side (workspace_tabs_controller.js,
# localStorage), so a reload or a shared link never depends on stored state.
#
# A `fresh` visit (no tab in the URL — the sidebar link) is not a new tab:
# the controller reopens the FIRST open tab, or, with none open, makes this
# visit the first. The content stays invisible until that decision, so the
# page under it never flashes.
#
# The server draws the current tab so the strip has no empty first paint; the
# controller then redraws the whole list from storage. The block is the page
# content.
class Components::UI::WorkspaceTabs < Components::Base
  TAB = "group relative flex items-center min-w-0 max-w-[220px] shrink-0 h-8 -mb-px border border-b-0 transition-colors " \
        "border-transparent text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 " \
        "aria-[current=page]:border-voodu-border aria-[current=page]:bg-voodu-surface aria-[current=page]:text-voodu-text"

  def initialize(storage_key:, tab_id:, label:, base_path:, prefs_prefix: "", fresh: false)
    @storage_key = storage_key
    @tab_id = tab_id
    @label = label
    @base_path = base_path
    @prefs_prefix = prefs_prefix
    @fresh = fresh
  end

  def view_template(&)
    div(
      class: "min-w-0",
      data: {
        controller: "workspace-tabs",
        workspace_tabs_storage_key_value: @storage_key,
        workspace_tabs_tab_id_value: @tab_id,
        workspace_tabs_label_value: @label,
        workspace_tabs_base_path_value: @base_path,
        workspace_tabs_prefs_prefix_value: @prefs_prefix,
        workspace_tabs_fresh_value: @fresh.to_s
      }
    ) do
      div(
        class: tokens("flex flex-col gap-4 vmd:gap-5 min-w-0", @fresh ? "invisible" : nil),
        data: {workspace_tabs_target: "content"}
      ) do
        tab_bar
        yield if block_given?
      end
    end
  end

  private

  def tab_bar
    div(class: "flex items-end gap-1 min-w-0 border-b border-voodu-border") do
      template(data: {workspace_tabs_target: "template"}) { tab_item(label: "", current: false) }

      div(
        role: "tablist",
        aria: {label: "Open tabs"},
        data: {workspace_tabs_target: "strip"},
        class: "flex items-end gap-1 min-w-0 overflow-x-auto scrollbar-hidden"
      ) do
        tab_item(label: @label, current: true, href: "#{@base_path}?#{request.query_string}")
      end

      add_button
    end
  end

  def tab_item(label:, current:, href: nil)
    div(class: TAB, role: "presentation", aria: current ? {current: "page"} : {}) do
      a(
        href: href,
        role: "tab",
        title: label,
        data: {tab_link: true},
        class: "flex items-center gap-1.5 min-w-0 h-full pl-3 pr-2 text-[11.5px] font-voodu-mono"
      ) do
        render Icon::PhoneArrowUpRightOutline.new(class: "w-3 h-3 shrink-0 opacity-70")
        span(class: "truncate", data: {tab_label: true}) { label }
      end

      button(
        type: "button",
        hidden: true,
        title: "Close tab",
        "aria-label": "Close tab",
        data: {tab_close: true, action: "click->workspace-tabs#closeTab"},
        class: "inline-flex items-center justify-center w-5 h-5 mr-1.5 shrink-0 text-voodu-muted-2 hover:text-voodu-text hover:bg-voodu-surface-2"
      ) { render Icon::XMarkOutline.new(class: "w-3 h-3") }
    end
  end

  def add_button
    button(
      type: "button",
      title: "New tab",
      "aria-label": "New tab",
      data: {workspace_tabs_target: "add", action: "click->workspace-tabs#newTab"},
      class: "inline-flex items-center justify-center w-8 h-8 mb-px shrink-0 text-voodu-muted hover:text-voodu-text " \
             "hover:bg-voodu-surface-2 disabled:opacity-40 disabled:cursor-not-allowed"
    ) { render Icon::PlusOutline.new(class: "w-3.5 h-3.5") }
  end
end
