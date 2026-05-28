# frozen_string_literal: true

require "rails/railtie"
require "fileutils"

module LogPoller
  # Railtie — Rails-side wiring for the log_poller gem.
  #
  # On boot:
  #   - Copies `gems/log_poller/bin/log-poller` into the Rails app's
  #     `bin/` directory if it does not already exist. The shipped file
  #     is a thin Ruby shim that boots the app and calls
  #     `LogPoller::Runner.start`.
  #
  # No middleware, no initializers — keeps the surface tiny.
  class Railtie < Rails::Railtie
    config.log_poller = ActiveSupport::OrderedOptions.new

    initializer "log_poller.install_binstub" do |app|
      template = File.join(LogPoller::GEM_ROOT, "bin", "log-poller")
      target   = app.root.join("bin", "log-poller").to_s

      next if File.exist?(target)
      next unless File.exist?(template)

      FileUtils.cp(template, target)
      File.chmod(0o755, target)
    rescue StandardError => e
      Rails.logger.warn("[log_poller] failed to install binstub: #{e.class}: #{e.message}") if Rails.logger
    end
  end
end
