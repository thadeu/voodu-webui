# frozen_string_literal: true

# MetricsRecord — abstract base for every model whose data lives in
# the `metrics` SQLite database (the time-series warehouse populated
# by MetricsSync jobs).
#
# Rails 8 multi-DB convention: `connects_to` must live on an
# `abstract_class = true` ancestor, not on the concrete model. Trying
# to `connects_to` directly on MetricSample blows up at class load
# because ApplicationRecord already owns its own connection.
#
# This is the same pattern Rails generates for solid_cache /
# solid_queue / solid_cable — each ships its own MetricsRecord-style
# base class.
class MetricsRecord < ApplicationRecord
  self.abstract_class = true

  connects_to database: { writing: :metrics, reading: :metrics }
end
