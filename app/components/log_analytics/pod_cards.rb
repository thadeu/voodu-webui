# frozen_string_literal: true

# Components::LogAnalytics::PodCards — the pod scope as a grid of toggle
# cards (same card language as the Metrics display settings: status dot,
# corner check, mono name). Used by the ScopeGate, where the choice is the
# whole point of the screen — a dropdown would hide the very thing the
# operator is being asked to decide.
#
# Each card is a <label> around a sr-only checkbox, so the selected look is
# pure CSS (`has-[:checked]`) — no JS repaint to fall out of sync. The
# checkboxes carry NO `name`: the gate never submits on its own, it hands
# the selection to the filter form (see log_scope_gate_controller), which
# stays the single source of truth for `pods[]`.
#
# The first card is "All pods" — explicit, because an empty selection no
# longer means "scan everything" (LogSearchData#scope_chosen?).
#
#   selected: container names in the applied scope; all: the applied scope is
#   "all pods". Both empty/false = nothing applied yet (the controller then
#   pre-selects the remembered scope, or All pods).
class Components::LogAnalytics::PodCards < Components::Base
  CARD = "group relative flex flex-col gap-1.5 min-w-0 p-3 border cursor-pointer select-none transition-colors " \
         "border-voodu-border bg-voodu-surface hover:bg-voodu-surface-2 hover:border-voodu-border-2 " \
         "has-[:checked]:border-voodu-accent-line has-[:checked]:bg-voodu-accent-dim " \
         "has-[:focus-visible]:outline has-[:focus-visible]:outline-1 has-[:focus-visible]:outline-voodu-accent"

  def initialize(pods:, selected: [], all: false)
    @pods = Array(pods).reject { |pod| pod_name(pod).blank? }
    @selected = Array(selected).map(&:to_s)
    @all = all && @selected.empty?
  end

  def view_template
    div(class: "grid grid-cols-1 @md:grid-cols-2 @2xl:grid-cols-3 @4xl:grid-cols-4 gap-2") do
      all_card
      sorted_pods.each { |pod| pod_card(pod) }
    end
  end

  private

  # Sorted by scope, then name — two scopes
  # on one server can both own a "web".
  def sorted_pods
    @pods.sort_by { |pod| [pod_scope(pod), pod_label(pod), pod_name(pod)] }
  end

  def all_card
    label(class: CARD, data: {log_scope_gate_target: "allCard"}) do
      input(
        type: "checkbox",
        checked: @all,
        class: "sr-only",
        data: {log_scope_gate_target: "all", action: "change->log-scope-gate#toggleAll"}
      )

      card_top do
        render Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 text-voodu-muted group-has-[:checked]:text-voodu-accent-2")
        span(class: "text-[10px] font-voodu-mono uppercase tracking-[0.05em] text-voodu-muted-2") { "everything" }
      end

      span(class: "text-[12.5px] font-semibold text-voodu-text leading-tight") { "All pods" }
      span(class: "text-[10.5px] text-voodu-muted leading-tight") do
        plain "#{@pods.size} #{(@pods.size == 1) ? "pod" : "pods"} · "
        span(class: "text-voodu-amber") { "slowest scan" }
      end
    end
  end

  def pod_card(pod)
    label(
      class: CARD,
      title: pod_name(pod),
      data: {log_scope_gate_target: "card", search: "#{pod_scope(pod)} #{pod_label(pod)} #{pod_name(pod)}".downcase}
    ) do
      input(
        type: "checkbox",
        value: pod_name(pod),
        checked: @selected.include?(pod_name(pod)),
        class: "sr-only",
        data: {log_scope_gate_target: "pod", action: "change->log-scope-gate#togglePod"}
      )

      card_top do
        render Components::UI::StatusDot.new(status: (pod_status(pod).presence || "running").to_sym, size: 6)
        span(class: "text-[10px] font-voodu-mono uppercase tracking-[0.05em] text-voodu-muted-2 truncate") { pod_kind(pod) }
      end

      span(class: "text-[12.5px] font-semibold font-voodu-mono text-voodu-text truncate leading-tight") { pod_label(pod) }
      span(class: "text-[10.5px] font-voodu-mono text-voodu-muted truncate leading-tight") { pod_meta(pod) }
    end
  end

  # card_top — the leading marker on the left, the selected check pinned right.
  def card_top(&block)
    div(class: "flex items-center gap-1.5 min-w-0") do
      yield

      span(class: "ml-auto shrink-0 text-voodu-accent-2 invisible group-has-[:checked]:visible") do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
      end
    end
  end

  def pod_name(pod)
    (pod[:name] || pod["name"]).to_s
  end

  def pod_label(pod)
    (pod[:resource_name] || pod["resource_name"]).presence || pod_name(pod)
  end

  def pod_status(pod)
    (pod[:status] || pod["status"]).to_s
  end

  def pod_kind(pod)
    (pod[:kind] || pod["kind"]).presence || "pod"
  end

  def pod_scope(pod)
    (pod[:scope] || pod["scope"]).presence || "(default)"
  end

  # pod_meta — "scope · replica" so two replicas of one resource stay apart.
  def pod_meta(pod)
    replica = (pod[:replica_id] || pod["replica_id"]).presence

    [pod_scope(pod), replica].compact.join(" · ")
  end
end
