# frozen_string_literal: true

# Components::Pods::DeploymentStrip — which commit put this pod here.
#
# THE OTHER HALF OF THE LOOP. The deployment screen links to the pods a commit
# created; this links back. Together they turn the chart on this very page into
# an answer: "that spike started at the deploy of abc1234" stops being a
# deduction somebody makes from two timestamps and becomes a link they click.
#
# RENDERS NOTHING when this pod was never deployed from a repository. Most pods
# on most boxes are applied by hand from the CLI, and a strip saying "no
# deployment" on every one of them would be a permanent empty row on the
# busiest page in the product.
class Components::Pods::DeploymentStrip < Components::Base
  # Two, not one. The newest answers "what is running"; the one before it
  # answers "what changed", which is the question somebody on a pod page at 2am
  # is actually asking.
  LIMIT = 2

  def initialize(server:, scope:, name:)
    @server = server
    @scope = scope
    @name = name
  end

  def view_template
    return if @server.nil? || @name.blank?

    deployments = Deployment.for_pod(server: @server, scope: @scope, name: @name, limit: LIMIT)

    return if deployments.empty?

    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 " \
               "border border-voodu-border bg-voodu-surface px-3 py-2") do
      label
      div(class: "flex flex-wrap items-center gap-1.5 min-w-0") do
        deployments.each_with_index { |deployment, index| entry(deployment, index) }
      end
    end
  end

  private

  def label
    span(class: "text-[11px] uppercase tracking-[0.06em] text-voodu-muted shrink-0") { "Deployed from" }
  end

  def entry(deployment, index)
    a(href: deploys_deployment_path(id: deployment.id),
      title: deployment.commit_message.to_s,
      class: entry_class(index)) do
      span(class: "font-voodu-mono text-[11.5px]") { deployment.short_sha }

      # The message only on the newest. Two subjects side by side is a strip
      # that wraps on a phone to say something the detail page says better.
      if index.zero? && deployment.commit_message.present?
        span(class: "hidden vmd:inline text-[11.5px] truncate max-w-[22rem]") do
          deployment.commit_message
        end
      end
    end
  end

  def entry_class(index)
    base = "flex items-center gap-1.5 px-2 py-1 border no-underline min-w-0 "

    base + if index.zero?
      "border-voodu-border-2 bg-voodu-surface-2 text-voodu-link"
    else
      "border-voodu-border text-voodu-muted"
    end
  end
end
