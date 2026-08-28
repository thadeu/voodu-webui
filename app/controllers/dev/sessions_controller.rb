# frozen_string_literal: true

module Dev
  # Dev::SessionsController — sign in without a Clowk instance.
  #
  #   /dev/sign_in?email=you@example.com
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

      email = params[:email].presence || "operator@example.com"
      token = ClowkDevToken.mint(sub: "dev-#{Digest::SHA256.hexdigest(email)[0, 16]}", email: email)

      cookies[Clowk.config.cookie_key] = {value: token, httponly: true, same_site: :lax}

      redirect_to params[:return_to].presence || "/", allow_other_host: false
    end
  end
end
