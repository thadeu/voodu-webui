# frozen_string_literal: true

# Single sign-on — how people prove who they are to this installation.
#
# Split out of a single "Installation" screen, which described the SCOPE rather
# than the subject: both live at the container level, but one is what you bought
# and the other is how people get in. Nobody looking for either searches for
# "installation".
class Views::AuthConfigs::Show < Views::Base
  def initialize(current_path:, servers: [])
    @current_path = current_path
    @servers = servers
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, breadcrumb: [{label: "SSO"}]
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        page_header
        div(class: "max-w-3xl") { auth_card }
      end
    end
  end

  private

  def page_header
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Single sign-on" }
      p(class: "text-[12.5px] text-voodu-muted") { plain "Which provider proves who someone is — or whether this installation asks at all." }
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
end
