# frozen_string_literal: true

require "test_helper"

# A grep, as a test.
#
# Tenant scoping in this app is enforced at ONE boundary: a Server (or an Org)
# reaches request code only through ApplicationController#reachable_servers,
# #authorized_servers or Current.user.active_orgs. Everything downstream —
# MetricsWarehouse, the HEP scopes, LogTail's file paths, every dashboard panel
# — takes the object it is handed and files its rows under a bare integer
# `server_id` with no org column and no foreign key. There is nothing further
# down that could notice a wrong one.
#
# So the rule is not "remember to scope your query". It is: **request code must
# never name these models directly.** That is mechanically checkable, which is
# the whole point — the previous rule was "remember", and the audit that
# started this work found ten places where nobody had.
class TenantScopingTest < ActiveSupport::TestCase
  # Reads only. `.new` builds an unsaved object for a form and reaches no rows.
  LOOKUPS = %w[find find_by find_by! where all first last order count exists? pluck joins].freeze

  SCANNED = ["app/controllers", "app/views", "app/components"].freeze

  EXEMPT = [
    # The producer's own home: reachable_servers is the one place allowed to
    # turn nothing into a Server relation.
    "app/controllers/application_controller.rb",
    # Machine plane: ActionController::API, authenticated by POLLER_TOKEN and a
    # private-IP guard, and global BY DESIGN — the poller needs every server.
    "app/controllers/internal"
  ].freeze

  test "request code never looks up a tenant-scoped model directly" do
    pattern = /\b(Server|Org|MetricSample|HepMessage|HepCursor)\.(#{LOOKUPS.map { Regexp.escape(it) }.join("|")})\b/

    offenders = ruby_files.filter_map do |path|
      hits = File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.strip.start_with?("#") # a comment naming the rule is not a breach of it

        "#{path}:#{i + 1}  #{line.strip}" if line.match?(pattern)
      end

      hits.presence
    end.flatten

    assert_empty offenders, <<~MESSAGE
      Request code must reach servers and orgs through the scoped producers:

        authorized_servers        — servers in the current org this person may see
        reachable_servers         — the same, across every org they belong to
        Current.user.active_orgs  — orgs they belong to

      A bare lookup answers for every tenant in the install, and nothing
      downstream can tell the difference. Found:

      #{offenders.join("\n")}
    MESSAGE
  end

  private

  def ruby_files
    SCANNED.flat_map { |dir| Dir.glob(Rails.root.join(dir, "**", "*.rb")) }
      .reject { |path| EXEMPT.any? { |prefix| path.include?(prefix) } }
  end
end
