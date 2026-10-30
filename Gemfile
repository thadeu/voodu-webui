source "https://rubygems.org"

ruby File.read(".ruby-version").strip

gem "rails", "~> 8.1.3"
gem "propshaft"
gem "sqlite3", "~> 2.1"

# Postgres for the primary database, and only when DATABASE_URL says so — the
# self-hosted install stays on the six SQLite files. `require: false` because
# the driver is dead weight in that install: Rails resolves adapters lazily and
# active_record/connection_adapters/postgresql_adapter.rb requires "pg" itself
# the moment a Postgres connection is actually configured.
#
# The image already carries what this needs: libpq-dev in the build stage and
# postgresql-client in the runtime base, both there long before this line.
gem "pg", "~> 1.5", require: false
gem "puma", ">= 5.0"
gem "jsbundling-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "cssbundling-rails"
gem "jbuilder"
gem "bcrypt", "~> 3.1.7"
gem "tzinfo-data", platforms: %i[windows jruby]
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"
gem "bootsnap", require: false
gem "thruster", require: false
gem "phlex-rails", "~> 2.4"
gem "phlex-icons", "~> 2.56"
gem "faraday", "~> 2.12"
gem "csv", "~> 3.3", require: false

# clowk — optional operator sign-in (hosted Clowk.in identity). Inert
# unless CLOWK_AUTH_ENABLED=1 plus both keys are present; see
# config/initializers/clowk.rb. No user table: the gem verifies the JWT
# and keeps the claims in the Rails session.
gem "clowk", "~> 0.6"

# contagorda-pay — how a customer of the HOSTED service buys Pro. Checkout,
# cancel and resume from the console, and the webhook that moves the plan.
# Inert everywhere else: with no PAY_SECRET_KEY the upgrade button is not
# drawn, and a self-hosted box never reads an account's paid plan at all (see
# Entitlements#plan).
gem "contagorda-pay", "~> 0.1"

# poller — Go-based NDJSON poller for voodu servers. Ships a compiled
# binary that the Puma plugin (config/puma.rb) always spawns: it is the only
# thing that fills the warehouse, and Poller::Railtie refuses to boot without
# it. Built with `make -C gems/poller build` — Bundler will not build it
# (path gems install with extensions disabled). Path-resolved local gem; no
# rubygems.org publish.
gem "poller", path: "gems/poller"

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "standard", require: false
  gem "dotenv-rails"
end

group :test do
  gem "webmock", require: false

  # Minitest 6 dropped minitest/mock from the gem; it now ships separately.
  # Loaded in test_helper so `stub` is available the way it always was.
  gem "minitest-mock", require: false
end
