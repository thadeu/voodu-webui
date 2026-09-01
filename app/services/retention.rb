# frozen_string_literal: true

# Retention — two windows, and they are not the same number.
#
#   keep_days  — how long bytes stay on disk. Set by the OPERATOR, never by the
#                licence, and honoured by the Go poller, which owns the sweep.
#
#   serve_days — how far back a query may look. Capped by the LICENCE, and
#                never more than what is actually kept.
#
# Splitting them is the whole safety property of licensed retention. If the
# licence drove deletion, letting one lapse would erase a customer's history —
# not degrade the product, damage their data, at the exact moment they are
# deciding whether to renew. So a lapse narrows what can be SEEN and touches
# nothing on disk: renew, and the window reopens over bytes that never left.
#
# The consequence, stated plainly for the operator: an Enterprise install that
# wants 90 days of searchable logs must also tell the container to keep 90 days
# (VOODU_RETENTION_DAYS=90). Buying the entitlement does not silently start
# consuming their disk.
class Retention
  # What the free tier keeps, and the floor everything else starts from. Matches
  # the sweeper's historical behaviour so an upgrade changes nothing by itself.
  DEFAULT_KEEP_DAYS = LogTail::FilePath::RETENTION_DAYS

  def self.keep_days
    configured = ENV["VOODU_RETENTION_DAYS"].to_s.strip
    return DEFAULT_KEEP_DAYS unless /\A\d+\z/.match?(configured)

    [configured.to_i, 1].max
  end

  # You cannot serve what was never kept, and you may not serve past what was
  # bought. The smaller of the two is the honest answer.
  def self.serve_days(entitlements = Entitlements.current)
    [keep_days, entitlements.retention_days].min
  end

  def self.serve_window(entitlements = Entitlements.current)
    serve_days(entitlements).days
  end
end
