# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Tests opt in to fixtures via `fixtures :islands` etc. — no
    # global `fixtures :all` because the suite is just starting up
    # and not every model has a fixture file yet.
    parallelize(workers: 1)
  end
end
