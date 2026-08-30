# frozen_string_literal: true

# The confirmation that hands an anonymous installation's workspace to a real
# identity — shown once, after the person has actually signed in.
#
# The order is the safety. Turning on Clowk touches nothing; this screen only
# appears once a Clowk login has succeeded, which is proof the credentials were
# right. Get here and the migration is safe to make; never get here and the
# operator restarts with CLOWK_ENABLED=0 having lost nothing.
#
# Chrome-less like onboarding, and for the same reason: the sidebar and server
# switcher would both be empty for someone who owns nothing yet.
class Views::AuthMigrations::Show < Views::Base
  def initialize(orgs:, servers:, owner_email:)
    @orgs = orgs
    @servers = servers
    @owner_email = owner_email
  end

  def view_template
    div(class: "min-h-screen flex items-center justify-center px-4 bg-voodu-surface") do
      div(class: "w-full max-w-md flex flex-col gap-6") do
        heading
        summary_card
        sign_out_row
      end
    end
  end

  private

  def heading
    div(class: "flex flex-col gap-1.5") do
      h1(class: "text-[19px] font-semibold text-voodu-text") { "Take over this workspace" }
      p(class: "text-[13px] text-voodu-muted") do
        plain "This installation was running without sign-in. Everything it holds can move " \
              "to your account now."
      end
    end
  end

  # Counts rather than a bare yes/no: the operator should recognise their own
  # installation before handing it anywhere.
  def summary_card
    div(class: "flex flex-col gap-4 p-5 border border-voodu-border bg-voodu-bg") do
      div(class: "flex flex-col gap-2") do
        row("Orgs", @orgs)
        row("Servers", @servers)
        row("Moving to", @owner_email)
      end

      form(action: auth_migration_path, method: "post", class: "flex flex-col gap-2") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        render Components::UI::Button.new(type: "submit", variant: :primary) { "Take over the workspace" }
      end

      p(class: "text-[11.5px] text-voodu-muted") do
        plain "Nothing has changed yet. Sign out and restart with "
        code(class: "font-voodu-mono") { "CLOWK_ENABLED=0" }
        plain " to go back to anonymous instead."
      end
    end
  end

  def row(label, value)
    div(class: "flex items-baseline justify-between gap-3") do
      span(class: "text-[12px] text-voodu-muted") { label }
      span(class: "text-[13px] font-voodu-mono text-voodu-text truncate") { value.to_s }
    end
  end

  def sign_out_row
    div(class: "flex flex-col vmd:flex-row vmd:items-center vmd:justify-center gap-1 vmd:gap-2 " \
               "text-[12px] text-voodu-muted") do
      span { "Signed in as #{current_user&.email}" }
      a(href: clowk_sign_out_path, class: "text-voodu-link hover:underline") { "Sign out" }
    end
  end
end
