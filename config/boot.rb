ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# An empty database URL is not a URL — it is an operator who did not set one.
#
# Rails disagrees loudly: ConnectionUrlResolver raises "Database URL cannot be
# empty" and the app never boots. And an empty value is the NORMAL case for the
# self-hosted install, because docker-compose.yml declares environment as a map
# (`DATABASE_URL: ${DATABASE_URL:-}`), which always interpolates something — an
# empty string when the variable is unset. The list form (`- DATABASE_URL`)
# would pass it through only when set, but the whole block would have to be
# converted, so the tolerance lives here instead.
#
# Done before Rails reads any of them, and for the per-database variants too
# (CACHE_DATABASE_URL, METRICS_DATABASE_URL, …), which fail exactly the same way.
ENV.keys.grep(/\ADATABASE_URL\z|_DATABASE_URL\z/).each do |key|
  ENV.delete(key) if ENV[key].to_s.strip.empty?
end
