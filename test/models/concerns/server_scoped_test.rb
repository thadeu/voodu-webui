# frozen_string_literal: true

require "test_helper"

# The tripwire on the stores that hold a bare server_id and nothing else.
# Authorization happens once, upstream, when authorized_servers turns a URL
# into a Server — so downstream the OBJECT is the capability, and an integer is
# a caller who skipped that step.
class ServerScopedTest < ActiveSupport::TestCase
  test "every leaf entry point refuses a bare id" do
    id = servers(:alpha).id

    assert_raises(ArgumentError) { MetricSample.last_ts_for(id) }
    assert_raises(ArgumentError) { HepCursor.cursor_for(id, "fsw", "hep3-api") }
    assert_raises(ArgumentError) { HepMessage.for_instance(server: id, scope: "fsw", name: "x").to_a }
    assert_raises(ArgumentError) { HepMessage.locate_by_call_id(id, "call-1") }
    assert_raises(ArgumentError) { LogTail::FilePath.server_dir(id) }
    assert_raises(ArgumentError) { LogTail::FilePath.list_pods(id) }
  end

  test "the refusal names the reason, not just the type" do
    error = assert_raises(ArgumentError) { MetricSample.last_ts_for(1) }

    assert_match(/expected a Server/, error.message)
    assert_match(/no org column/, error.message)
  end

  test "a Server is accepted" do
    server = servers(:alpha)

    assert_equal 0, MetricSample.last_ts_for(server)
    assert_equal "", HepCursor.cursor_for(server, "fsw", "hep3-api")
    assert_match %r{storage/logs/#{server.id}\z}, LogTail::FilePath.server_dir(server).to_s
  end

  # A double that answers #id would sail straight past the one check standing
  # between a caller and another tenant's data.
  test "a double that merely answers #id is not a Server" do
    double = Struct.new(:id).new(servers(:gamma).id)

    assert_raises(ArgumentError) { MetricSample.last_ts_for(double) }
  end
end
