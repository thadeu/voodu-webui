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

# Secrets the entrypoint persisted to the volume, for processes that did not
# come through the entrypoint.
#
# `bin/docker-entrypoint` generates SECRET_KEY_BASE, the three ActiveRecord
# Encryption keys and POLLER_TOKEN on first boot, writes them under
# /rails/storage, and exports them — for the Puma it then execs. A
# `docker exec <ctr> bin/rails console` (or runner, or a rake task) never runs
# the entrypoint, so it booted with none of them: reading a PAT raised
# "Missing Active Record encryption credential", and every one-off had to be
# prefixed with the entrypoint by hand. Loading the same files here, only when
# the variable is absent, makes the app self-sufficient: an operator-supplied
# value still wins, the entrypoint still owns generation, and a checkout
# without the volume (dev, test, CI) sees no file and changes nothing.
storage = ENV.fetch("VOODU_STORAGE_DIR", "/rails/storage")

{"SECRET_KEY_BASE" => ".secret_key_base", "POLLER_TOKEN" => ".poller_token"}.each do |key, file|
  path = File.join(storage, file)
  ENV[key] = File.read(path).strip if ENV[key].to_s.empty? && File.file?(path)
end

ar_env = File.join(storage, ".ar_encryption.env")

if ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].to_s.empty? && File.file?(ar_env)
  File.foreach(ar_env) do |line|
    key, value = line.strip.split("=", 2)
    ENV[key] = value if key && value && ENV[key].to_s.empty?
  end
end
