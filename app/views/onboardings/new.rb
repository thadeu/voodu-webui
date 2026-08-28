# frozen_string_literal: true

# Views::Onboardings::New — the first screen after a first sign-in.
#
# Deliberately chrome-less: the Dashboard layout renders a server switcher and
# a sidebar that would both be empty here, and the only thing this person can
# do is fill in two names.
class Views::Onboardings::New < Views::Base
  def initialize(account_name:, org_name:, error: nil)
    @account_name = account_name
    @org_name = org_name
    @error = error
  end

  def view_template
    div(class: "min-h-screen flex items-center justify-center px-4 bg-voodu-surface") do
      div(class: "w-full max-w-md flex flex-col gap-6") do
        heading
        form_card
        sign_out_row
      end
    end
  end

  private

  # The way out. Without it this screen is a dead end for anyone who signed in
  # as the wrong identity — the only other exit is clearing a cookie by hand.
  def sign_out_row
    div(class: "flex flex-col vmd:flex-row vmd:items-center vmd:justify-center " \
               "gap-1 vmd:gap-2 text-[12px] text-voodu-muted") do
      span { "Signed in as #{current_user&.email}" }
      a(href: clowk_sign_out_path, class: "text-voodu-link hover:underline") { "Sign out" }
    end
  end

  def heading
    div(class: "flex flex-col gap-1.5") do
      h1(class: "text-[19px] font-semibold text-voodu-text") { "Set up your workspace" }
      p(class: "text-[13px] text-voodu-muted") do
        "An account groups your orgs; an org groups your servers. You can add more of both later."
      end
    end
  end

  def form_card
    form(
      action: onboarding_path, method: "post",
      class: "flex flex-col gap-4 p-5 bg-voodu-surface-2 border border-voodu-border rounded-lg"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

      error_banner if @error

      field(label: "Account name", hint: "Your company or your own name.") do
        text_input(name: "account_name", value: @account_name)
      end

      field(label: "First org", hint: "A group of servers — production, staging, a client.") do
        text_input(name: "org_name", value: @org_name)
      end

      render Components::UI::Button.new(type: "submit", variant: :primary) { "Create workspace" }
    end
  end

  # Local, like every other form view here (text_input is defined per view, not
  # shared — input_classes on Views::Base is the shared part).
  def text_input(name:, value: nil)
    input(type: "text", name: name, value: value, autocomplete: "off", class: input_classes)
  end

  def error_banner
    div(class: "text-[12px] text-voodu-red border border-voodu-red/40 rounded px-3 py-2") { @error }
  end
end
