# frozen_string_literal: true

# Components::Base is the root Phlex class every voodu-webui component
# inherits from. Mirrors the clowk pattern (same Rails helpers wired,
# same Icon alias, same tokens() helper) so muscle memory carries over
# between the two codebases.
#
# Two responsibilities:
#
#   1. Pull in the Rails view helpers Phlex doesn't expose by default
#      (link_to, form_with, routes, etc.) so components can use them
#      without each subclass re-including.
#   2. Alias PhlexIcons::Hero as `Icon` so the call site reads
#      `Icon.ArrowRightIcon` — terse, scannable, and lets us swap
#      icon families later by editing one line.
#
# In development we emit an HTML comment before each template render
# (also borrowed from clowk) — turns the DOM tree into a free
# annotated map for "which component drew which div?" debugging.
class Components::Base < Phlex::HTML
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::DOMID
  include Phlex::Rails::Helpers::Flash
  include Phlex::Rails::Helpers::LinkTo
  include Phlex::Rails::Helpers::ButtonTo
  include Phlex::Rails::Helpers::FormWith
  include Phlex::Rails::Helpers::ContentFor
  include Phlex::Rails::Helpers::ContentTag
  include Phlex::Rails::Helpers::CurrentPage
  include Phlex::Rails::Helpers::Request
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Phlex::Rails::Helpers::TurboFrameTag
  include Phlex::Rails::Helpers::TurboStreamFrom

  # Custom helpers exposed by ApplicationController via `helper_method`.
  # `register_value_helper` is the post-phlex-2.4 replacement for the
  # deprecated `helpers.X` indirection — it auto-defines a method that
  # forwards to view_context internally, so callers write `flash`,
  # `recent_islands`, etc. directly.
  #
  # Routes (metrics_path, pod_logs_path, etc.) are already exposed by
  # `Phlex::Rails::Helpers::Routes` above; CSRF + custom controller
  # helpers need explicit registration:
  register_value_helper :form_authenticity_token
  register_value_helper :recent_islands
  # current_island — the focused server, for components that gate an
  # affordance on a plugin (e.g. the Logs→HEP3 call-flow chip only shows
  # when `current_island.plugin_installed?("hep3")`). Cheap: the island +
  # its System row + parsed payload are all memoised, so a per-row check
  # stays free.
  register_value_helper :current_island

  Icon = PhlexIcons::Hero

  if Rails.env.development?
    def before_template
      comment { "Before #{self.class.name}" }
      super
    end
  end

  private

  # tokens merges CSS class strings, filtering nil/false/empty.
  # Letting callers write:
  #
  #   tokens("px-3 py-2", variant_classes, error && "border-red")
  #
  # without hand-rolling the join+compact dance every time.
  def tokens(*classes)
    classes.flatten.compact.reject { |c| [false, ""].include?(c) }.join(" ").squish
  end
end
