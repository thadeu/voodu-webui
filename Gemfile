source "https://rubygems.org"

ruby File.read(".ruby-version").strip

gem "rails", "~> 8.1.3"
gem "propshaft"
gem "sqlite3", "~> 2.1"
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
gem "image_processing", "~> 1.2"
gem "phlex-rails", "~> 2.4"
gem "phlex-icons", "~> 2.56"
gem "faraday", "~> 2.12"
gem "csv", "~> 3.3", require: false

# poller — Go-based NDJSON poller for voodu islands. Ships a
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
end
