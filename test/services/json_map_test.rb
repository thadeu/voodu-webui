# frozen_string_literal: true

require "test_helper"

# JsonMap resolves the panel mapping DSL against an external API's JSON. Pins
# the paths that matter: nested keys, array indices, the array/lone-object
# coercion the row/point set relies on, and graceful nil on any miss.
class JsonMapTest < ActiveSupport::TestCase
  DOC = {
    "data" => {"items" => [{"name" => "a", "m" => {"cpu" => 42}}, {"name" => "b", "m" => {"cpu" => 7}}]},
    "count" => 2
  }.freeze

  test "dig walks nested keys and array indices" do
    assert_equal 42, JsonMap.dig(DOC, "data.items[0].m.cpu")
    assert_equal "b", JsonMap.dig(DOC, "data.items[1].name")
    assert_equal 2, JsonMap.dig(DOC, "count")
  end

  test "dig accepts a leading $ / $. and an empty path returns the value itself" do
    assert_equal 42, JsonMap.dig(DOC, "$.data.items[0].m.cpu")
    assert_equal DOC, JsonMap.dig(DOC, "")
    assert_equal DOC, JsonMap.dig(DOC, "$")
  end

  test "dig returns nil on any miss (wrong key, wrong type, out of range)" do
    assert_nil JsonMap.dig(DOC, "data.nope.x")
    assert_nil JsonMap.dig(DOC, "count.x")          # scalar can't be indexed by key
    assert_nil JsonMap.dig(DOC, "data.items[9].name") # out of range
  end

  test "array_at returns the array, wraps a lone object, and [] on miss" do
    assert_equal 2, JsonMap.array_at(DOC, "data.items").size
    assert_equal [{"cpu" => 42}], JsonMap.array_at(DOC, "data.items[0].m")
    assert_equal [], JsonMap.array_at(DOC, "data.nope")
  end

  test "array_at with an empty root wraps a top-level object into one row" do
    assert_equal [DOC], JsonMap.array_at(DOC, "")
    assert_equal [1, 2, 3], JsonMap.array_at([1, 2, 3], "")
  end
end
