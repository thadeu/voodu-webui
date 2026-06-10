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
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"
gem "bootsnap", require: false
gem "kamal", require: false
gem "thruster", require: false
gem "image_processing", "~> 1.2"
gem "phlex-rails", "~> 2.4"
gem "phlex-icons", "~> 2.56"
gem "faraday", "~> 2.12"

# csv — stdlib in Ruby ≤3.3, bundled gem from Ruby 3.4 onward
# (must be in the Gemfile to load). Used by LogTail::LineFormatter for
# the /logs/analytics CSV export. `require: false` — LineFormatter does
# its own `require "csv"`.
gem "csv", "~> 3.3", require: false

# poller — Go-based NDJSON poller for voodu islands. Ships a
# compiled binary that the Puma plugin (config/puma.rb) spawns when
# `POLLER_SPAWN=1`. Path-resolved local gem; no rubygems.org publish.
gem "poller", path: "gems/poller"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  gem "dotenv-rails"
end

group :test do
  # webmock — block real outbound HTTP in tests. Island health probes
  # (IslandHealth#probe → Voodu::Client) hit the controller endpoint on
  # render; against an unreachable fixture host that means a multi-second
  # connect timeout PER render. With WebMock the connection is refused
  # instantly, probe's rescue → :offline, and renders stay in-process.
  # `require: false` — loaded explicitly by test_helper.
  gem "webmock", require: false
end
