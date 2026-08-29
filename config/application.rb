require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module VooduWebui
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

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
