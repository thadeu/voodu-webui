# frozen_string_literal: true

class Views::Base < Components::Base
  # The `Views::Base` is an abstract class for all your views.

  # By default, it inherits from `Components::Base`, but you
  # can change that to `Phlex::HTML` if you want to keep views and
  # components independent.

  # More caching options at https://www.phlex.fun/components/caching
  def cache_store = Rails.cache

  # overview_crumbs — standard breadcrumb trail rooted at the current
  # server's Overview, for the Dashboard `breadcrumb:` kwarg. Pass the
  # trail AFTER Overview as { label:, href: } hashes (last = current,
  # rendered as plain text). Returns [] when there's no server so the
  # NoServerState pages render no crumb. Management pages (no server)
  # build their crumbs inline instead.
  def overview_crumbs(*trail)
    return [] if @current_server.nil?

    key = @current_server.key

    [{label: "Overview", href: server_root_path(server_key: key)}, *trail]
  end

  # field — a labeled form control with an optional hint / inline error: the
  # standard New/Edit-modal field wrapper (Name, Endpoint, Metric…). The control
  # markup is the yielded block; an error takes precedence over the hint below
  # it. Shared by every modal form (alert rule, destination, server).
  def field(label:, hint: nil, error: nil)
    div(class: "flex flex-col gap-1.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { label }

      yield

      if error
        div(class: "text-[11.5px] text-voodu-red inline-flex items-center gap-1.5") do
          span(class: "inline-block w-[5px] h-[5px] rounded-full bg-voodu-red", "aria-hidden": "true")
          span { error }
        end
      elsif hint
        div(class: "text-[11.5px] text-voodu-muted") { hint }
      end
    end
  end

  # input_classes — the base <input> styling shared by every modal-form text
  # field (h-9, surface bg, accent focus ring). Callers layer size / mono
  # classes on top via `tokens(input_classes, …)`.
  def input_classes
    "w-full px-3 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none " \
      "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line placeholder:text-voodu-muted-2"
  end

  # dropdown_filter / dropdown_empty — the in-menu type-to-filter box (sticky
  # top) + "no matches" row that the `dropdown` Stimulus controller drives.
  # Shared by every filterable DS dropdown (the alert-rule form's target /
  # metric pickers, the metrics builder's source / log pickers). Render inside
  # the menu; the controller shows/hides options + the empty row as you type.
  # (The menu container's own width/height classes stay per-caller — they
  # legitimately differ — so those aren't hoisted here.)
  def dropdown_filter(placeholder)
    div(class: "sticky top-0 z-10 bg-voodu-surface border-b border-voodu-border-2 p-1.5") do
      input(
        type: "text", placeholder: placeholder, autocomplete: "off", spellcheck: "false",
        data: {dropdown_target: "filter", action: "input->dropdown#filterInput keydown->dropdown#onFilterKey"},
        class: "w-full h-8 px-2.5 bg-voodu-surface-2 border border-voodu-border text-voodu-text text-[12px] " \
               "placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
      )
    end
  end

  def dropdown_empty
    div(hidden: true, data: {dropdown_target: "empty"}, class: "px-3 py-3 text-[12px] text-voodu-muted text-center") { "No matches" }
  end
end
