# frozen_string_literal: true

# Components::Metrics::ReplicaChips — only rendered when a POD scope
# is active AND that pod has sibling replicas. Lets the operator
# flip between replicas of the same (kind, scope, name) without
# going back through the scope picker.
#
# Each chip is a link — clicking sends the operator to
# /metrics?scope_kind=pod&scope_id=<container> for that sibling,
# preserving the active range.
class Components::Metrics::ReplicaChips < Components::Base
  def initialize(active_container:, siblings: [])
    @active_container = active_container
    @siblings         = Array(siblings)
  end

  def view_template
    return if @siblings.size < 2

    div(class: "flex items-center gap-2 flex-wrap") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.05em] text-voodu-muted") { "replicas" }

      @siblings.each do |s|
        chip(s)
      end
    end
  end

  private

  def chip(sibling)
    container = sibling[:name] || sibling["name"]
    replica   = sibling[:replica_id] || sibling["replica_id"]
    status    = (sibling[:status] || sibling["status"] || "running").to_s.to_sym
    active    = container == @active_container

    a(
      href: replica_url(container),
      data: { turbo: false },
      class: tokens(
        "inline-flex items-center gap-1.5 px-2 py-[3px] border font-voodu-mono text-[11.5px]",
        active ? "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2" : "border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2"
      )
    ) do
      render Components::UI::StatusDot.new(status: status, size: 6)
      span { ".#{replica}" }
    end
  end

  def replica_url(container)
    params = helpers.request.query_parameters.merge(scope_kind: "pod", scope_id: container)
    "#{helpers.metrics_path}?#{params.to_query}"
  end
end
