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
  end

  ENV_FLAG = "CLOWK_ENABLED"
  ENV_KEY = "CLOWK_PUBLISHABLE_KEY"
  TRUTHY = %w[1 true yes on].freeze

  def self.env_decides?
    ENV[ENV_FLAG].to_s.strip.present? || ENV[ENV_KEY].to_s.strip.present?
  end

  def self.current
    return from_env if env_decides?

    from_database
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
      subdomain_url: ENV["CLOWK_SUBDOMAIN_URL"].presence,
      secret_key: ENV["CLOWK_SECRET_KEY"].presence, source: :env
    )
  end

  def self.from_database
    config = AuthConfig.current
    return Resolved.new(enabled: false, source: :none) if config.nil?

    Resolved.new(
      enabled: true, publishable_key: config.publishable_key,
      subdomain_url: config.subdomain_url.presence,
      secret_key: config.secret_key.presence, source: :database
    )
  rescue ActiveRecord::ActiveRecordError => e
    # Authentication must never be the reason a page 500s, and the table may
    # simply not exist yet on an install mid-migration.
    Rails.logger.error("[auth] could not read the stored auth config: #{e.class}")
    Resolved.new(enabled: false, source: :none)
  end

  # apply! — make the Clowk gem agree with `settings`, and only when it does not
  # already. Reconfiguring on every request would throw away the JWKS cache that
  # keeps sign-in off the network.
  def self.apply!(settings = current)
    return if Clowk.config.publishable_key == settings.publishable_key &&
      Clowk.config.subdomain_url == settings.subdomain_url

    Clowk.configure do |config|
      config.publishable_key = settings.publishable_key
      config.subdomain_url = settings.subdomain_url
      config.secret_key = settings.secret_key || Clowk.config.secret_key
    end

    Rails.logger.info("[auth] Clowk credentials applied from #{settings.source}")
  rescue Clowk::ConfigurationError => e
    Rails.logger.error("[auth] refusing invalid Clowk credentials from #{settings.source}: #{e.message}")
  end
end
