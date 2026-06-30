# frozen_string_literal: true

# HepRecord — abstract base for every model whose data lives in the
# `hep` SQLite database (the SIP-capture read model the Hep3 poller
# fills from the voodu-hep3 reader's /export NDJSON tail).
#
# Same Rails 8 multi-DB convention as MetricsRecord: `connects_to` must
# sit on an `abstract_class = true` ancestor, never on the concrete
# model (ApplicationRecord already owns the primary connection).
class HepRecord < ApplicationRecord
  self.abstract_class = true

  connects_to database: {writing: :hep, reading: :hep}
end
