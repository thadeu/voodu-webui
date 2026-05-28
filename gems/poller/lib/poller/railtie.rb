# frozen_string_literal: true

require "rails/railtie"
require "fileutils"

module Poller
  # Railtie — Rails-side wiring for the poller gem.
  #
  # On boot:
  #   - Copies `gems/poller/bin/poller` into the Rails app's
  #     `bin/` directory if it does not already exist. The shipped file
  #     is a thin Ruby shim that boots the app and calls
  #     `Poller::Runner.start`.
  #
  # No middleware, no initializers — keeps the surface tiny.
  class Railtie < Rails::Railtie
    config.poller = ActiveSupport::OrderedOptions.new

    initializer "poller.install_binstub" do |app|
      template = File.join(Poller::GEM_ROOT, "bin", "poller")
      target   = app.root.join("bin", "poller").to_s

      next if File.exist?(target)
      next unless File.exist?(template)

      FileUtils.cp(template, target)
      File.chmod(0o755, target)
    rescue StandardError => e
      Rails.logger.warn("[poller] failed to install binstub: #{e.class}: #{e.message}") if Rails.logger
    end
  end
end
