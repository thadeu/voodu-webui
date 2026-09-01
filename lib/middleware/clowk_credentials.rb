# frozen_string_literal: true

module Middleware
  # Puts this installation's Clowk credentials in force for one request.
  #
  # MIDDLEWARE AND NOT AN around_action, and that is the whole reason this file
  # exists. Clowk::BaseController inherits from ActionController::Base, not from
  # ours, so the engine's own controllers — /sign_in and, more importantly, the
  # OAuth callback that VERIFIES THE TOKEN — never run our filters. A controller
  # filter would have covered every page except the two that decide whether
  # somebody is signed in at all, and it would have looked right in every test
  # that pins credentials in the environment.
  #
  # This replaces AuthSettings.apply!, which reached into Clowk.configure from
  # inside a request. That worked because the gem's configuration is a process
  # global, which is also why it was wrong: request-scoped code mutating
  # process-wide state, with Puma threads in attendance. Clowk 0.6 scopes
  # credentials per execution context instead, and this is where the scope
  # opens.
  #
  # Appended to the end of the stack (`config.middleware.use`), so it sits
  # inside ActionDispatch::Static and the executor: static assets never reach
  # it, and the database is connected by the time it reads.
  #
  # Streaming is safe. ActionController::Live runs the action in a spawned
  # thread, and IsolatedExecutionState is per thread — but Live calls
  # `share_with` to copy the state across, and it copies rather than shares, so
  # this middleware's `ensure` on the original thread cannot pull the
  # credentials out from under a stream still writing.
  class ClowkCredentials
    # The resolved settings, handed to the controllers so `clowk_enabled?` does
    # not repeat the database read this already paid for.
    ENV_KEY = "voodu.auth_settings"

    def initialize(app)
      @app = app
    end

    def call(env)
      settings = AuthSettings.effective
      env[ENV_KEY] = settings

      # Nothing to scope when sign-in is off: no credential is read on that
      # path, and installing one would be a lie about what governs the request.
      return @app.call(env) unless settings.enabled?

      Clowk.with_credentials(settings.to_clowk) { @app.call(env) }
    end
  end
end
