# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = {"cache-control" => "public, max-age=3600"}

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = {host: "example.com"}

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Sign-in is OFF by default (the self-hosted shape), but the suite is almost
  # entirely about the multi-tenant path — memberships, per-server grants, the
  # cross-tenant refusals. Pinned on here so those keep testing what they were
  # written to test; the anonymous-mode tests turn it off per-test. Set BEFORE
  # config/initializers/clowk.rb runs, which is why that file only fills in a
  # nil (environment files load first).
  config.x.clowk_enabled = true

  # The pin above is not enough on its own, because AuthSettings reads ENV
  # DIRECTLY — `env_decides?` asks whether the environment holds either of
  # these, and the answer decides whether the SSO screen offers its form or
  # explains that the host has already chosen.
  #
  # dotenv loads a developer's .env in the test environment too. So a working
  # .env with CLOWK_ENABLED=1 in it — which is exactly what a .env looks like
  # on the machine of anybody developing the hosted shape — silently turns 13
  # tests red, on code they did not touch, for a reason nothing in the failure
  # names. CI has no .env and stays green, which is the worst version of this:
  # it reads as "the suite is flaky locally" and the suite stops being trusted.
  #
  # The licence pair is here for the same reason: LicenseToken.token_from_env
  # reads VOODU_LICENSE, and license_test has a case named "when the env var is
  # empty" whose whole premise is that nobody set one.
  #
  # Deleted rather than blanked so `ENV.key?` is false too, and the tests that
  # are ABOUT these (sso_configuration_test, anonymous_mode_test, license_test)
  # set what they need per-test and restore it.
  %w[CLOWK_ENABLED CLOWK_PUBLISHABLE_KEY VOODU_LICENSE VOODU_LICENSE_FILE].each do |key|
    ENV.delete(key)
  end

  # Fixtures store PAT values as plaintext (e.g. "pat-alpha-secret")
  # so test files stay readable; this flag tells Rails to encrypt
  # them on fixture load using the test-only encryption keys
  # (config/initializers/active_record_encryption.rb).
  config.active_record.encryption.encrypt_fixtures = true
end
