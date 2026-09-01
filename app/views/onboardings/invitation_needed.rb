# frozen_string_literal: true

# What somebody sees when they signed in and there is nothing here for them.
#
# This installation holds one account and it already has one, so there is no
# workspace for this person to create — the only way in is for somebody who is
# already inside to invite them.
#
# Shown INSTEAD of the setup form, not as an error on top of it. Offering a
# form that cannot succeed invites somebody to name their workspace, choose an
# org, submit, and only then be told it was never possible. The refusal has to
# come before the work, not after it.
class Views::Onboardings::InvitationNeeded < Views::Base
  # The address comes in rather than being read from current_user: this page is
  # also rendered at the DOOR, before anyone is provisioned, and at that moment
  # there is no user to ask.
  def initialize(email: nil)
    @email = email
  end

  def view_template
    div(class: "min-h-screen flex items-center justify-center px-4 bg-voodu-surface") do
      div(class: "w-full max-w-md flex flex-col gap-6") do
        heading
        explanation
        sign_out_row
      end
    end
  end

  private

  def heading
    div(class: "flex flex-col gap-1.5") do
      h1(class: "text-[19px] font-semibold text-voodu-text") { "You need an invitation" }
      p(class: "text-[13px] text-voodu-muted") do
        plain "Your sign-in worked. This installation just has nothing assigned to you yet."
      end
    end
  end

  # Names the specific thing to ask for, and who to ask. "Contact your
  # administrator" is what a page says when it does not know either.
  def explanation
    div(class: "flex flex-col gap-3 p-4 border border-voodu-border bg-voodu-surface-2") do
      p(class: "m-0 text-[13px] leading-relaxed text-voodu-text-2") do
        plain "Ask whoever runs this installation to invite "
        span(class: "font-voodu-mono text-voodu-text") { address }
        plain " into their org. They can do it from "
        span(class: "font-voodu-mono text-voodu-text-2") { "Members" }
        plain ", and you will be in the moment you sign in again."
      end

      p(class: "m-0 text-[12px] text-voodu-muted") do
        plain "Signed in with the wrong address? Sign out and try the one they invited."
      end
    end
  end

  def address = @email.presence || current_user&.email.to_s

  # The way out. Without it this screen is a dead end for anyone who signed in
  # as the wrong identity — the only other exit is clearing a cookie by hand.
  def sign_out_row
    div(class: "flex flex-col vmd:flex-row vmd:items-center vmd:justify-center " \
               "gap-1 vmd:gap-2 text-[12px] text-voodu-muted") do
      span { "Signed in as #{address}" }
      a(href: clowk_sign_out_path, class: "text-voodu-link hover:underline") { "Sign out" }
    end
  end
end
