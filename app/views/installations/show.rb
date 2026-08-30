# frozen_string_literal: true

# Views::Installations::Show — settings that belong to the INSTALLATION.
#
# Separate from Views::Settings::Index on purpose. That screen lives at
# /:org_id/:server_key/settings and configures one server; the licence and the
# authentication method configure the whole container. Putting them there meant
# an operator with no server registered could not reach their own licence, and
# implied per-server settings that are nothing of the kind.
#
# Same split the routes already had: POST /license and POST /auth_config were
# top-level from the start. This is the screen catching up with them.
class Views::Installations::Show < Views::Base
  def initialize(current_path:, servers: [])
    @current_path = current_path
    @servers = servers
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, breadcrumb: [{label: "Installation"}]
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        page_header

        div(class: "flex flex-col gap-4 vmd:gap-5 max-w-3xl") do
          plan_card
          auth_card
        end
      end
    end
  end

  private

  def page_header
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Installation" }
      p(class: "text-[12.5px] text-voodu-muted") do
        plain "The licence and sign-in method for this container — not for one server."
      end
    end
  end

  # ── Authentication ─────────────────────────────────────────────────

  def auth_card
    settings = AuthSettings.current

    render Components::UI::SectionCard.new(title: "Authentication") do
      div do
        render(Components::UI::KvRow.new(key: "Sign-in")) { auth_state_value(settings) }
        render(Components::UI::KvRow.new(key: "Configured by")) { auth_source_value(settings) }
      end

      auth_form(settings) if allowed?(:manage_account)
    end
  end

  def auth_state_value(settings)
    if settings.enabled?
      span(class: "text-voodu-text") { "Clowk — every request carries an identity" }
    else
      span(class: "text-voodu-amber") { "Anonymous — the perimeter authenticates" }
    end
  end

  def auth_source_value(settings)
    label = {env: "Environment variables", database: "This screen", none: "—"}.fetch(settings.source)

    span(class: "text-[12px] text-voodu-text-2") { label }
  end

  # Environment wins, so when it is in play the form would be a lie. Say why
  # instead of showing a control that silently does nothing.
  def auth_form(settings)
    return auth_env_notice if AuthSettings.env_decides?
    return auth_disable_form if settings.source == :database

    form(action: auth_config_path, method: "post",
      class: "flex flex-col gap-2 pt-3 mt-3 border-t border-voodu-border") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "return_to", value: @current_path)

      auth_field("publishable_key", "Publishable key", "pk_live_…", required: true)
      auth_field("owner_email", "Your Clowk email — you will be offered this workspace after signing in",
        "you@company.com", required: true)
      auth_field("subdomain_url", "Auth domain (optional)", "https://auth.company.com")

      div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 pt-1") do
        render Components::UI::Button.new(type: "submit", variant: :primary, size: :sm) { "Migrate to Clowk" }
        span(class: "text-[11.5px] text-voodu-muted") do
          plain "Nothing moves until you sign in and confirm. Recover with CLOWK_ENABLED=0."
        end
      end
    end
  end

  def auth_field(name, label_text, placeholder, required: false)
    div(class: "flex flex-col gap-1") do
      label(class: "text-[12px] text-voodu-muted", for: "auth-#{name}") { label_text }
      input(
        id: "auth-#{name}", name: name, type: "text", placeholder: placeholder, required: required,
        class: "w-full font-voodu-mono text-[12px] px-2.5 py-1.5 bg-voodu-surface-2 " \
               "border border-voodu-border text-voodu-text focus:outline-none focus:border-voodu-accent"
      )
    end
  end

  def auth_env_notice
    p(class: "text-[12px] text-voodu-muted pt-3 mt-3 border-t border-voodu-border") do
      plain "Sign-in is set by environment variables here, which take precedence over " \
            "this screen. Change CLOWK_ENABLED or CLOWK_PUBLISHABLE_KEY there."
    end
  end

  def auth_disable_form
    form(action: auth_config_path, method: "post",
      class: "flex flex-col vmd:flex-row vmd:items-center gap-2 pt-3 mt-3 border-t border-voodu-border") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "return_to", value: @current_path)

      render Components::UI::Button.new(type: "submit", variant: :danger, size: :sm) { "Turn off sign-in" }
      span(class: "text-[11.5px] text-voodu-muted") do
        plain "Returns to anonymous — keep a VPN in front."
      end
    end
  end

  # ── Plan ───────────────────────────────────────────────────────────

  # Its own card rather than a row in About, because it is the only place an
  # operator can act on their licence: see what they have, and paste a new one.
  # Renewal without a restart is the point — the alternative is editing an env
  # var and bouncing the dashboard someone is watching.
  def plan_card
    render Components::UI::SectionCard.new(title: "Plan") do
      div do
        render(Components::UI::KvRow.new(key: "Plan")) { plan_value }
        render(Components::UI::KvRow.new(key: "Expires")) { plan_expiry_value } if license.present?
        render(Components::UI::KvRow.new(key: "Limits")) { plan_limits_value }
        render(Components::UI::KvRow.new(key: "Database")) { database_value }
      end

      license_history if allowed?(:manage_account)
      activation_form if allowed?(:manage_account)
    end
  end

  # Every licence this installation has run under.
  #
  # The rows were always being written — one per activation — and nothing showed
  # them. What they answer is the question support actually gets asked: when did
  # this installation become Enterprise, under whose name, and who pasted it.
  # Owner-only, same bracket as the form, because it names people.
  # Extracted rather than inline: it is a filtered table, and the house already
  # has a shape for those (Components::Orgs::MembersTable).
  def license_history
    keys = LicenseKey.newest_first.to_a
    return if keys.empty?

    div(class: "flex flex-col gap-1.5 pt-3 mt-3 border-t border-voodu-border") do
      span(class: "text-[11px] uppercase tracking-wide text-voodu-muted") { "License history" }
      render Components::Licenses::HistoryTable.new(keys: keys)
    end
  end

  def plan_limits_value
    e = entitlements

    span(class: "font-voodu-mono text-[12px] text-voodu-text-2") do
      plain "#{plan_count(e.limit(:orgs))} orgs · "
      plain "#{plan_count(e.limit(:member_invites))} invites · "
      plain "#{e.retention_days}d searchable"
      plain " · Postgres" if e.postgres?
    end
  end

  def plan_count(value) = value.nil? ? "∞" : value.to_s

  # The licence grants the OPTION of Postgres; DATABASE_URL is how an operator
  # takes it. Both facts belong here, because "am I on Postgres" and "may I be"
  # are different questions and only one of them is about the plan.
  def database_value
    postgres = primary_adapter.start_with?("postgres")

    span(class: "font-voodu-mono text-[12px]") do
      span(class: "text-voodu-text") { postgres ? "Postgres" : "SQLite" }
      span(class: "text-voodu-muted") { " · control plane" }
      span(class: "text-voodu-muted") { " · warehouse always SQLite" }
    end
  end

  def activation_form
    form(action: license_path, method: "post", class: "flex flex-col gap-2 pt-3 mt-3 border-t border-voodu-border") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "return_to", value: @current_path)

      label(class: "text-[12px] text-voodu-muted", for: "license-token") do
        plain license.present? ? "Replace the licence" : "Activate a licence"
      end

      textarea(
        id: "license-token", name: "license_token", rows: "3",
        placeholder: "eyJhbGciOiJSUzI1NiJ9…",
        class: "w-full font-voodu-mono text-[11.5px] break-all px-2.5 py-2 " \
               "bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
               "focus:outline-none focus:border-voodu-accent"
      )

      div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2") do
        render Components::UI::Button.new(type: "submit", variant: :primary, size: :sm) { "Activate" }
        span(class: "text-[11.5px] text-voodu-muted") do
          plain "Takes effect immediately — no restart."
        end
      end
    end
  end

  # ── Plan values ────────────────────────────────────────────────────

  def license = License.current

  # Shown even on the free tier, and deliberately: an operator who cannot see
  # which plan they are on files a ticket to ask. A lapsed or unverifiable
  # licence has to be loud here — it is the only place that explains why a
  # capability they paid for stopped applying.
  def plan_value
    case license.status
    when :none
      span(class: "text-voodu-text-2") { "Free" }
    when :valid
      span(class: "text-voodu-text") { "Enterprise · #{license.customer}" }
    when :grace
      span(class: "text-voodu-amber") { "Enterprise · #{license.customer} — expired, in grace" }
    when :lapsed
      span(class: "text-voodu-red") { "Free — licence for #{license.customer} lapsed" }
    when :invalid
      span(class: "text-voodu-red") { "Free — licence could not be verified" }
    end
  end

  def plan_expiry_value
    expires = license.expires_at
    return span(class: "text-voodu-muted") { "—" } if expires.nil?

    days = license.days_until_expiry
    tone = if days.negative? then "text-voodu-red"
    elsif days <= 30 then "text-voodu-amber"
    else "text-voodu-text-2"
    end

    span(class: "font-voodu-mono #{tone}") do
      plain expires.to_date.to_s
      plain days.negative? ? " (#{days.abs}d ago)" : " (in #{days}d)"
    end
  end
end
