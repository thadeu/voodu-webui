# frozen_string_literal: true

module Dev
  # Dev::SessionsController — sign in without a Clowk instance.
  #
  #   /dev/sign_in?email=you@example.com   mints a token for that address
  #   /dev/sign_in                         asks which address
  #
  # ASKING is the whole point of the second form. This route is where
  # `require_authentication!` sends anybody signed out, so minting a token for a
  # default address the moment it is reached makes signing out do nothing
  # visible: the cookie is cleared, "/" bounces straight back here, a fresh
  # token for the same address is issued, and the operator lands exactly where
  # they started. It reads as a broken button. It also makes testing anything
  # with two people in it — an invitation, a transfer, a removal — impossible,
  # because there is no way to become somebody else.
  #
  # The explicit `?email=` form still mints immediately, so scripts and
  # bookmarks are unaffected.
  #
  # Descends from ActionController::Base rather than ApplicationController for
  # the same reason the Clowk engine does: a sign-in route that runs the
  # authentication chain cannot be reached by anyone who needs it.
  #
  # The route exists only under Rails.env.development? (config/routes.rb) and
  # ClowkDevToken raises in production. Two locks, because a token minted here
  # is indistinguishable from one the broker issued.
  class SessionsController < ActionController::Base
    def create
      raise ActionController::RoutingError, "not available" unless Rails.env.development?

      email = params[:email].to_s.strip
      return render(html: picker.html_safe) if email.empty?

      token = ClowkDevToken.mint(sub: "dev-#{Digest::SHA256.hexdigest(email)[0, 16]}", email: email)

      cookies[Clowk.config.cookie_key] = {value: token, httponly: true, same_site: :lax}

      redirect_to params[:return_to].presence || "/", allow_other_host: false
    end

    private

    # Deliberately hand-written HTML with no layout: the layout renders the
    # dashboard chrome, which reads Current.user — the one thing nobody
    # standing here has.
    def picker
      <<~HTML
        <!doctype html><meta charset="utf-8"><title>Sign in (development)</title>
        <style>
          :root { color-scheme: dark }
          body { background:#0b0f0e; color:#e6edeb; font:15px/1.5 ui-sans-serif,system-ui,sans-serif;
                 display:grid; place-items:center; min-height:100vh; margin:0 }
          main { width:min(28rem,90vw) }
          h1 { font-size:1.05rem; font-weight:600; margin:0 0 .25rem }
          p { color:#8b9d97; font-size:.85rem; margin:0 0 1.25rem }
          form { display:flex; gap:.5rem }
          input { flex:1; min-width:0; padding:.6rem .75rem; border-radius:.5rem;
                  border:1px solid #24312d; background:#111917; color:inherit; font:inherit }
          button { padding:.6rem 1rem; border:0; border-radius:.5rem; background:#047857;
                   color:#fff; font:inherit; font-weight:500; cursor:pointer }
          button:hover { background:#036349 }
          ul { list-style:none; padding:0; margin:1.25rem 0 0 }
          li { border-top:1px solid #1b2523 }
          a { display:block; padding:.55rem .1rem; color:#9fb3ad; text-decoration:none;
              font-family:ui-monospace,monospace; font-size:.8rem }
          a:hover { color:#e6edeb }
        </style>
        <main>
          <h1>Sign in as</h1>
          <p>Development only. Any address works — an unknown one is a new signup.</p>
          <form method="get">
            #{return_to_field}
            <input name="email" type="email" placeholder="you@example.com" autofocus required>
            <button type="submit">Continue</button>
          </form>
          #{known_addresses}
        </main>
      HTML
    end

    def return_to_field
      target = params[:return_to].to_s
      return "" if target.empty?

      %(<input type="hidden" name="return_to" value="#{ERB::Util.html_escape(target)}">)
    end

    # One click to become somebody who already exists — which is most of what
    # this is used for: checking what an invited admin actually sees.
    def known_addresses
      rows = ::User.order(:created_at).limit(12).pluck(:email).compact_blank
      return "" if rows.empty?

      items = rows.map { |email|
        href = ERB::Util.html_escape(dev_sign_in_path(email: email, return_to: params[:return_to]))

        "<li><a href=\"#{href}\">#{ERB::Util.html_escape(email)}</a></li>"
      }

      "<ul>#{items.join}</ul>"
    end
  end
end
