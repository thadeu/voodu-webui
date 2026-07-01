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

  REGEXP_TIMEOUT = 1.0

  # ensure_regexp! — SQLite ships the `X REGEXP Y` *syntax* but not the
  # function, so the DataTable filter's `like /re/` clauses need us to
  # define it. This lives in (reloadable) app code, NOT a boot initializer,
  # on purpose: a dev server that predates the feature — or a reconnected
  # pool connection — picks it up on the next query, no restart. Guarded per
  # raw connection (an ivar on the connection object): registered once, then
  # a no-op. Call it before running a query that may use REGEXP.
  def self.ensure_regexp!
    raw = connection.raw_connection
    return if raw.instance_variable_defined?(:@voodu_regexp)

    raw.create_function("regexp", 2) do |func, pattern, value|
      func.result = regexp_match?(pattern, value) ? 1 : 0
    end

    raw.instance_variable_set(:@voodu_regexp, true)
  end

  # regexp_match? — case-insensitive (matches LogQuery), with a per-match
  # timeout as the ReDoS backstop. A bad pattern / timeout is a non-match:
  # never blow up a query over a pattern the editor already validates.
  def self.regexp_match?(pattern, value)
    return false if pattern.nil? || value.nil?

    value.to_s.match?(Regexp.new(pattern.to_s, Regexp::IGNORECASE, timeout: REGEXP_TIMEOUT))
  rescue RegexpError
    false
  end
end
