# frozen_string_literal: true

# A deployment's outcome, in one chip.
#
# `held` is amber: not a failure, not done either — a push waiting for
# somebody to press play. The one status on this screen that asks for a hand.
#
# `skipped` is deliberately NOT red. A push that matched no trigger file — a
# README change on a repository that watches `app/**` — is the normal outcome,
# and colouring it like a failure trains operators to ignore failures.
class Components::Deployments::StatusBadge < Components::Base
  VARIANTS = {
    "queued" => :neutral,
    "running" => :info,
    "succeeded" => :success,
    "failed" => :danger,
    "skipped" => :neutral,
    "held" => :warning
  }.freeze

  def initialize(status:)
    @status = status.to_s
  end

  def view_template
    render Components::UI::Badge.new(variant: VARIANTS.fetch(@status, :neutral)) { @status }
  end
end
