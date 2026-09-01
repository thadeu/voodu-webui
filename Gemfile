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

# poller — Go-based NDJSON poller for voodu servers. Ships a
# compiled binary that the Puma plugin (config/puma.rb) spawns when
# `POLLER_SPAWN=1`. Path-resolved local gem; no rubygems.org publish.
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
