require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# ActiveStorage, ActionText and ActionMailbox are deliberately NOT loaded.
# Nothing here attaches a file, holds rich text or receives mail — their
# migrations were never even installed, so the schema has none of their
# tables. What they did cost was real: ActiveStorage's variant processor
# pulled `image_processing` → ruby-vips → the native libvips, which the
# production boot then required on every host. Add them back with
# `rails active_storage:install` if a file upload ever arrives; with no
# tables and no data there is nothing to migrate back.

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Not autoloadable, and required by hand: the middleware stack takes a real
# class at boot (it stopped constantizing strings), and referencing an
# autoloaded constant while initializers run is what Zeitwerk refuses. `lib/
# middleware` is therefore excluded from autoload_lib below.
require_relative "../lib/middleware/clowk_credentials"

module VooduWebui
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks middleware])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Which Clowk instance answers for each request. Appended, so it runs inside
    # ActionDispatch::Static and the executor — static assets never reach it,
    # and the database is connected by the time it reads. See the class for why
    # this is middleware and not an around_action.
    config.middleware.use Middleware::ClowkCredentials

    # db/schema.rb has to LOAD on both adapters — the self-hosted install runs
    # SQLite, the SaaS runs Postgres on the primary — so only SQLite may WRITE
    # it. One `bin/rails db:migrate` against Postgres rewrites the file in PG
    # dialect (`where: "pinned = true"` normalised to `where: "pinned"`,
    # `enable_extension "plpgsql"`, datetime precision) and the next
    # `db:prepare` on a SQLite install fails to load it.
    #
    # Keyed on DATABASE_URL rather than on the environment, because the
    # environment is not what decides the adapter here: DATABASE_URL is
    # (config/database.yml + database_configurations.rb, which feeds it to the
    # primary entry only). Development keeps dumping, which is how schema.rb
    # gets updated when someone adds a migration.
    config.active_record.dump_schema_after_migration = false if ENV["DATABASE_URL"].present?
  end
end
