# frozen_string_literal: true

require "test_helper"

class GithubSettingsTest < ActiveSupport::TestCase
  setup do
    Ops::GithubConfig.delete_all
    @saved = {}
  end

  teardown do
    @saved.each { |k, v| ENV[k] = v }
    Ops::GithubConfig.delete_all
  end

  def with_env(pairs)
    pairs.each_key { |k| @saved[k] = ENV[k] unless @saved.key?(k) }
    pairs.each { |k, v| ENV[k] = v }
  end

  # The header and footer are assembled from two halves so the fake never
  # matches test/architecture/no_private_keys_test.rb, which scans every
  # tracked file for a PEM header. That guard is the thing keeping the real
  # signing key out of git; teaching it to ignore this file would blunt it.
  PEM_HEADER = "-----BEGIN RSA PRIVATE " + "KEY-----"
  PEM_FOOTER = "-----END RSA PRIVATE " + "KEY-----"
  PEM = "#{PEM_HEADER}\nMIIabc\n#{PEM_FOOTER}\n"

  def store_config(**attrs)
    Ops::GithubConfig.create!({
      provider: "github", app_id: "123456", app_slug: "voodu-deploy",
      private_key: PEM, webhook_secret: "whsec"
    }.merge(attrs))
  end

  test "no config anywhere reads as unconfigured" do
    with_env(GithubSettings::ENV_APP_ID => nil)

    resolved = GithubSettings.current

    assert_not resolved.configured?
    assert_equal :none, resolved.source
  end

  test "a stored row configures the App without a redeploy" do
    with_env(GithubSettings::ENV_APP_ID => nil)
    store_config

    resolved = GithubSettings.current

    assert resolved.configured?
    assert_equal :database, resolved.source
    assert_equal "123456", resolved.app_id
    assert_equal "https://github.com/apps/voodu-deploy/installations/select_target", resolved.install_url
  end

  # THE safety rule. A wrong private key saved through a screen breaks every
  # deploy on the installation, and the screen that would fix it is behind the
  # same App. The environment is the way out, so it wins outright.
  test "the environment wins and the database is ignored entirely" do
    store_config(app_id: "999999", app_slug: "stored-app")

    with_env(
      GithubSettings::ENV_APP_ID => "111111",
      GithubSettings::ENV_APP_SLUG => "env-app",
      GithubSettings::ENV_PRIVATE_KEY => PEM
    )

    resolved = GithubSettings.current

    assert_equal :env, resolved.source
    assert_equal "111111", resolved.app_id
    assert_equal "env-app", resolved.app_slug
  end

  # An environment variable cannot hold a literal newline in most shells, so
  # the usual workaround is \n escapes — and a key with escaped newlines is not
  # a key. OpenSSL rejects it inside JWT signing, inside a deploy.
  test "a private key with escaped newlines is accepted" do
    with_env(
      GithubSettings::ENV_APP_ID => "111111",
      GithubSettings::ENV_PRIVATE_KEY => "#{PEM_HEADER}\\nMIIabc\\n#{PEM_FOOTER}"
    )

    key = GithubSettings.current.private_key

    assert_includes key, "\n"
    refute_includes key, '\n'
    assert key.start_with?("-----BEGIN")
  end

  test "a real multiline key passes through untouched" do
    with_env(GithubSettings::ENV_APP_ID => "1", GithubSettings::ENV_PRIVATE_KEY => PEM)

    assert_equal PEM, GithubSettings.current.private_key
  end

  # An App can mint tokens without a webhook secret, so a box would deploy on
  # demand while silently ignoring every push. "Works when I click, not when I
  # push" deserves its own question.
  test "webhook readiness is a separate question from being configured" do
    with_env(GithubSettings::ENV_APP_ID => nil)
    store_config(webhook_secret: nil)

    resolved = GithubSettings.current

    assert resolved.configured?
    assert_not resolved.webhook_ready?
  end

  # Either half alone is useless: an id with no key signs nothing, a key with
  # no id names nothing.
  test "an id without a key is not configured" do
    with_env(GithubSettings::ENV_APP_ID => "111111", GithubSettings::ENV_PRIVATE_KEY => nil)

    assert_not GithubSettings.current.configured?
  end

  # Append-only: saving writes a new row and leaves the old one, which is the
  # only record of who changed a key that reads every connected repository.
  test "the newest row wins and the previous one survives" do
    with_env(GithubSettings::ENV_APP_ID => nil)

    store_config(app_id: "111111")
    travel 1.second
    store_config(app_id: "222222")

    assert_equal 2, Ops::GithubConfig.count
    assert_equal "222222", GithubSettings.current.app_id
  end

  # GitHub's UI puts the client id (Iv1.…) beside the numeric App ID. Pasting
  # the wrong one produces a JWT that mints no token, and the failure lands in
  # a deploy rather than at save time.
  test "the client id is refused where the App id belongs" do
    config = Ops::GithubConfig.new(provider: "github", app_id: "Iv1.abc123", private_key: PEM)

    assert_not config.valid?
    assert_match(/numeric App ID/, config.errors[:app_id].join)
  end

  # A truncated paste is the most common way this goes wrong, and it has no
  # footer — telling somebody at save time beats an opaque signing error on
  # their first push.
  test "a truncated private key is refused" do
    config = Ops::GithubConfig.new(
      provider: "github", app_id: "123", private_key: "#{PEM_HEADER}\nMIIabc"
    )

    assert_not config.valid?
    assert_match(/BEGIN and END/, config.errors[:private_key].join)
  end

  # It reads every connected repository. It does not sit in the clear.
  test "the private key and webhook secret are encrypted at rest" do
    config = store_config

    raw = Ops::GithubConfig.connection.select_one(
      "SELECT private_key_ciphertext, webhook_secret_ciphertext FROM ops_github_configs WHERE id = #{config.id}"
    )

    refute_includes raw["private_key_ciphertext"].to_s, "MIIabc"
    refute_includes raw["webhook_secret_ciphertext"].to_s, "whsec"
    assert_equal PEM, config.reload.private_key
  end
end
