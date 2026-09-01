# frozen_string_literal: true

# AuthSettings — where sign-in gets its credentials, and who decides.
#
# Two sources, and the precedence is a SAFETY rule rather than a preference:
#
#   ENVIRONMENT WINS, always. If CLOWK_ENABLED or CLOWK_PUBLISHABLE_KEY is set,
#   the database is ignored entirely.
#
# That is the way out. A wrong publishable key saved through Settings would send
# every request to a Clowk instance that does not know the operator — locked out
# of their own dashboard, with no UI left to fix it from. Restarting with
# CLOWK_ENABLED=0 always returns them to anonymous mode, whatever is stored.
# Without that, a typo is unrecoverable without database surgery.
#
# Otherwise the stored config decides, so an operator can buy Clowk while
# already running and turn it on without a redeploy.
class AuthSettings
  Resolved = Struct.new(:enabled, :publishable_key, :subdomain_url, :secret_key, :source) do
    def enabled? = enabled == true

    # These settings as the gem's value object, for Clowk.with_credentials.
    #
    # There is no `apply!` any more, and its absence is the point. It called
    # Clowk.configure from inside a request, which mutates the gem's PROCESS
    # configuration — so one request's credentials stayed installed for every
    # request after it, on every Puma thread. On a self-hosted box with a single
    # instance that was invisible, which is the worst kind of wrong: it only
    # misbehaves where there is a second instance to confuse it with.
    #
    # Clowk 0.6 scopes credentials to a block instead, and
    # Middleware::ClowkCredentials opens that scope per request. Nothing global
    # is touched, so nothing has to be undone.
    #
    # The secret falls back to the boot configuration, which `apply!` also did
    # and which is not incidental. CLOWK_SECRET_KEY is read by the initializer
    # into Clowk.config; an operator who sets it there and then pastes only a
    # publishable key into the SSO screen must not silently lose it, because
    # without it legacy HS256 tokens stop verifying — and that failure lands in
    # the OAuth callback, the one request there is no retrying past.
    #
    # RS256 needs no secret at all, so this is empty on most installations.
    def to_clowk
      Clowk::Credentials.new(
        publishable_key: publishable_key,
        secret_key: secret_key || Clowk.config.secret_key,
        subdomain_url: subdomain_url
      )
    end
  end

  ENV_FLAG = "CLOWK_ENABLED"
  ENV_KEY = "CLOWK_PUBLISHABLE_KEY"
  TRUTHY = %w[1 true yes on].freeze

  # Every subdomain URL reaching the gem goes through here first, because the
  # gem will not do it: Clowk::Subdomain prepends the scheme when it is missing,
  # but Clowk::Jwks.default_url reads `config.subdomain_url` RAW and skips that
  # path entirely. A bare host therefore builds "host/.well-known/jwks.json",
  # which Net::HTTP rejects with `ArgumentError (not an HTTP URI)` — and it does
  # so inside the OAuth callback, so the failure is a 500 on the one request
  # that cannot be retried past. Nothing before that point complains: the app
  # boots, the sign-in redirect is built correctly by Subdomain, and only the
  # token verification on the way back explodes.
  #
  # `clowk.dev` and `https://clowk.dev` mean the same thing to whoever types
  # one into a form or an env var, so they are made to mean the same thing here
  # rather than one of them being a trap.
  def self.normalize_url(value)
    url = value.to_s.strip
    return nil if url.empty?
    return url if url.start_with?("http://", "https://")

    "https://#{url}"
  end

  def self.env_decides?
    ENV[ENV_FLAG].to_s.strip.present? || ENV[ENV_KEY].to_s.strip.present?
  end

  def self.current
    return from_env if env_decides?

    from_database
  end

  # effective — whether sign-in is ON right now, and with which credentials.
  #
  # The one answer every reader must share. `current` says what is CONFIGURED
  # and is what the SSO screen describes; this says what is IN FORCE, and adds
  # the one source `current` cannot see:
  #
  #   1. A REAL BOOLEAN pinned in config.x.clowk_enabled — an environment file
  #      said so outright, and the test env pins `true` so the suite keeps
  #      exercising the multi-tenant path.
  #   2. The ENVIRONMENT, via `current`. The way out of a wrong key saved
  #      through Settings.
  #   3. The DATABASE, via `current`. The row the SSO screen writes, which is
  #      how an operator turns sign-in on and off without a redeploy.
  #
  # Step 3 used to be unreachable. config/initializers/clowk.rb pinned the
  # ENVIRONMENT's answer into config.x.clowk_enabled even when the environment
  # had not answered — which is every self-hosted box — and clowk_enabled?
  # returned that pin without reading anything else. So turning sign-in on from
  # the screen stored a row that nothing consulted: the screen reported success,
  # the badge kept saying `none`, and every request kept running as the
  # anonymous operator with the dashboard wide open. See the initializer.
  def self.effective
    settings = current
    pin = pinned_flag

    return settings if pin.nil? || pin == settings.enabled?

    Resolved.new(
      enabled: pin, publishable_key: settings.publishable_key,
      subdomain_url: settings.subdomain_url, secret_key: settings.secret_key,
      source: settings.source
    )
  end

  # The boolean an environment file pinned, or nil when nobody decided there.
  #
  # NOT a nil check on the raw value: `config.x.anything_unset` returns an empty
  # ActiveSupport::OrderedOptions, which is neither nil NOR falsey — so a `.nil?`
  # or a bare truth test here would read "undecided" as "decided, and on".
  def self.pinned_flag
    value = Rails.application.config.x.clowk_enabled

    [true, false].include?(value) ? value : nil
  end

  def self.from_env
    flag = ENV[ENV_FLAG].to_s.strip.downcase
    key = ENV[ENV_KEY].to_s.strip

    # An unset flag with a key present means ON. An install already configured
    # for Clowk is one where somebody chose sign-in, and reading "unset" as
    # "anonymous" would silently open that dashboard on a restart.
    enabled = flag.empty? ? key.present? : TRUTHY.include?(flag)

    Resolved.new(
      enabled: enabled, publishable_key: key.presence,
      subdomain_url: normalize_url(ENV["CLOWK_SUBDOMAIN_URL"]),
      secret_key: ENV["CLOWK_SECRET_KEY"].presence, source: :env
    )
  end

  def self.from_database
    config = Ops::SsoConfig.current
    return Resolved.new(enabled: false, source: :none) if config.nil?

    # One provider today. When there is a second, this is where it branches —
    # the column already names which one, so nothing here needs a migration.
    return Resolved.new(enabled: false, source: :none) unless config.clowk?

    Resolved.new(
      enabled: true, publishable_key: config.publishable_key,
      subdomain_url: normalize_url(config.subdomain_url),
      secret_key: config.secret_key.presence, source: :database
    )
  rescue ActiveRecord::ActiveRecordError => e
    # Authentication must never be the reason a page 500s, and the table may
    # simply not exist yet on an install mid-migration.
    Rails.logger.error("[auth] could not read the stored auth config: #{e.class}")
    Resolved.new(enabled: false, source: :none)
  end
end
