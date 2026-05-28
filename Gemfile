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

# rubyzip — used by LogExportJob to bundle "group by pod" exports
# into a single .zip download (one .ndjson per pod inside). MIT
# license, no native extension, pure Ruby. Loaded only by the job
# (require "zip" inside #generate_zip!), so the rest of the app
# pays nothing for it.
gem "rubyzip", "~> 2.3", require: false

# csv — stdlib in Ruby ≤3.3, bundled gem from Ruby 3.4 onward
# (must be in the Gemfile to load). Used by LogExportJob's CSV
# output format. `require: false` because only the export job
# needs it; loaded on-demand via `require "csv"` inside the job.
gem "csv", "~> 3.3", require: false

# log_poller — Go-based NDJSON poller for voodu islands. Ships a
# compiled binary that the Puma plugin (config/puma.rb) spawns when
# `LOG_POLLER_SPAWN=1`. Path-resolved local gem; no rubygems.org publish.
gem "log_poller", path: "gems/log_poller"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  gem "dotenv-rails"
end
