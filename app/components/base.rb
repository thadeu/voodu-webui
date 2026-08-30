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
  # `recent_servers`, etc. directly.
  #
  # Routes (metrics_path, pod_logs_path, etc.) are already exposed by
  # `Phlex::Rails::Helpers::Routes` above; CSRF + custom controller
  # helpers need explicit registration:
  register_value_helper :form_authenticity_token
  register_value_helper :recent_servers
  # current_server — the focused server, for components that gate an
  # affordance on a plugin (e.g. the Logs→HEP3 call-flow chip only shows
  # when `current_server.plugin_installed?("hep3")`). Cheap: the server +
  # its System row + parsed payload are all memoised, so a per-row check
  # stays free.
  register_value_helper :current_server
  # current_org / all_orgs — the server layer above servers, for the topbar
  # org switcher + breadcrumb (org › servers › <server>).
  register_value_helper :current_org
  register_value_helper :all_orgs
  # current_user — the signed-in operator (a local ::User mirroring the Clowk
  # subject), for anything that shows who you are or offers a way out.
  register_value_helper :current_user
  # clowk_sign_out_path — the gem derives it from Clowk.config.mount_path, so
  # moving the engine's mount moves this with it. Registered because the gem
  # only installs its UrlHelpers into ActionView and ActionController, and a
  # Phlex component is neither.
  register_value_helper :clowk_sign_out_path
  # manageable_org — the org whose members this person may manage, or nil.
  register_value_helper :manageable_org
  # allowed?(:capability) — the same table the controllers enforce, for
  # deciding what to DRAW. Not a control: the endpoint refuses regardless.
  register_value_helper :allowed?
  # allowed_in?(org, capability) — the same question about a NAMED org, for the
  # chrome that renders on pages with no :org_id in the URL.
  register_value_helper :allowed_in?

  # Which deployment shape this is. Components use it to drop the surfaces that
  # only mean something with per-person identity — sign-out, invitations, the
  # members screen, the org switcher.
  register_value_helper :clowk_enabled?
  register_value_helper :perimeter_warning?
  register_value_helper :entitlements
  register_value_helper :unlicensed_postgres?

  # ── Form + dropdown primitives ─────────────────────────────────────────
  # Moved down from Views::Base when Components::UI::Select needed them: a
  # component is not a view, and CLAUDE.md's rule is that a primitive lives in
  # Components::UI before it gets duplicated. Views::Base inherits from here,
  # so every existing caller is unaffected.

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
