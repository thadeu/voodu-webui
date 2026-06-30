# frozen_string_literal: true

require "test_helper"

# Island#hep3_readers is the operator-configured list of reader instances
# the Hep3 poller tails (the reader is a plain deployment after expand, so
# it can't be auto-discovered). These pin the parse: scope/name pairs,
# blank/garbage tolerance, and per-island isolation.
class IslandHep3ReadersTest < ActiveSupport::TestCase
  fixtures :islands

  setup { @island = islands(:alpha) }

  test "parses scope/name entries from an array" do
    @island.hep3_readers = ["fsw/hep3-api", "ops/sip-cap"]

    assert_equal [{scope: "fsw", name: "hep3-api"}, {scope: "ops", name: "sip-cap"}],
      @island.hep3_readers
  end

  test "accepts a comma string and drops blanks + entries without a name" do
    @island.hep3_readers = "fsw/hep3-api, , bogus, ops/sip-cap"

    assert_equal [{scope: "fsw", name: "hep3-api"}, {scope: "ops", name: "sip-cap"}],
      @island.hep3_readers
  end

  test "is empty when unconfigured" do
    assert_equal [], @island.hep3_readers
  end

  test "is namespaced per island" do
    @island.hep3_readers = ["fsw/hep3-api"]

    assert_equal [], islands(:beta).hep3_readers, "one island's readers must not leak to another"
  end
end
