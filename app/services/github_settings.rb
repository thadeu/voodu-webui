# frozen_string_literal: true

# GithubSettings — where the deploy plane gets its GitHub App, and who decides.
#
# Two sources, and the precedence is the same SAFETY rule AuthSettings
# documents, for the same reason:
#
#   ENVIRONMENT WINS, always. If GITHUB_APP_ID is set, the database is ignored
#   entirely.
#
# That is the way out. A wrong private key saved through a screen breaks every
# deploy on the installation — including, on a hosted service, everybody
# else's. Restarting with the right value in the environment restores it
# without database surgery. Without that, one bad paste needs a console.
#
# Otherwise the stored row decides, so an operator can rotate an App or
# configure one for the first time without a redeploy.
#
# ONE APP FOR THE WHOLE INSTALLATION. A customer authorizes it on their
# repositories and we hold an installation_id; they never see these values.
# The eventual Enterprise sale is what makes the stored path matter — a
# customer bringing their own App configures it here rather than in our env.
class GithubSettings
  Resolved = Struct.new(:app_id, :app_slug, :private_key, :webhook_secret, :source) do
    # configured? — is there an App at all?
    #
    # The id and the key together, because either alone is useless: an id with
    # no key signs nothing, and a key with no id names nothing.
    def configured? = app_id.present? && private_key.present?

    # webhook_ready? — can a push actually be verified?
    #
    # Separate from `configured?` on purpose. An App can mint tokens without a
    # webhook secret, so a box can deploy on demand while silently ignoring
    # every push — and "deploys work when I click but not when I push" is a
    # confusing enough symptom to deserve its own question.
    def webhook_ready? = configured? && webhook_secret.present?

    # Where an operator sends a customer to authorize the App. Derived, never
    # stored: a stored URL is one more thing that can disagree with the App it
    # names.
    def install_url
      return nil if app_slug.blank?

      "https://github.com/apps/#{app_slug}/installations/new"
    end
  end

  ENV_APP_ID = "GITHUB_APP_ID"
  ENV_APP_SLUG = "GITHUB_APP_SLUG"
  ENV_PRIVATE_KEY = "GITHUB_APP_PRIVATE_KEY"
  ENV_WEBHOOK_SECRET = "GITHUB_WEBHOOK_SECRET"

  def self.env_decides?
    ENV[ENV_APP_ID].to_s.strip.present?
  end

  def self.current
    return from_env if env_decides?

    from_database
  end

  # normalize_private_key — accepts a PEM however an operator managed to get it
  # into a variable.
  #
  # An environment variable cannot hold a literal newline in most shells, so
  # the usual workaround is `\n` escapes — and a key with escaped newlines is
  # not a key: OpenSSL rejects it, inside the JWT signing, inside a deploy.
  # Accepting both spellings here costs one substitution and removes a failure
  # that surfaces three layers from its cause.
  def self.normalize_private_key(value)
    key = value.to_s

    return nil if key.strip.empty?

    key.include?('\n') ? key.gsub('\n', "\n") : key
  end

  def self.from_env
    Resolved.new(
      ENV[ENV_APP_ID].to_s.strip.presence,
      ENV[ENV_APP_SLUG].to_s.strip.presence,
      normalize_private_key(ENV[ENV_PRIVATE_KEY]),
      ENV[ENV_WEBHOOK_SECRET].to_s.strip.presence,
      :env
    )
  end

  def self.from_database
    config = Ops::GithubConfig.current

    return Resolved.new(nil, nil, nil, nil, :none) if config.nil?
    return Resolved.new(nil, nil, nil, nil, :none) unless config.github?

    Resolved.new(
      config.app_id.presence,
      config.app_slug.presence,
      normalize_private_key(config.private_key),
      config.webhook_secret.presence,
      :database
    )
  rescue ActiveRecord::ActiveRecordError => e
    # A missing table on an install mid-migration must not 500 a page. The
    # deploy plane simply reports itself unconfigured, which is true.
    Rails.logger.error("[github] could not read the stored App config: #{e.class}")
    Resolved.new(nil, nil, nil, nil, :none)
  end
end
