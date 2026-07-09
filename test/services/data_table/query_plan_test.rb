# frozen_string_literal: true

require "test_helper"

# Exercises the pipeline PARSER — the "reduce" stages (filter | count()/
# count(distinct) by field | sort | limit) → a structured aggregation plan.
# Pure parse: no SQL, no DB. The SQL + allowlist live in M2 (Hep3Source).
class DataTable::QueryPlanTest < ActiveSupport::TestCase
  def plan(src) = DataTable::QueryPlan.compile(src)

  test "empty query → an empty plan (no filter, no aggregation)" do
    p = plan("")

    assert_equal "", p.filter
    assert_not p.aggregate?
    assert_not p.grouped?
    assert p.valid?
  end

  test "a filter with no aggregation stays a plain filter (backward-compat)" do
    p = plan("@to_user like /5511/")

    assert_equal "(@to_user like /5511/)", p.filter
    assert_not p.aggregate?, "no count() ⇒ not an aggregation (read path treats it as a table)"
    assert_nil p.group_by
  end

  test "count() with no field aggregates the whole set (one series)" do
    p = plan("| count()")

    assert_equal :count, p.aggregate
    assert_nil p.distinct_field
    assert_nil p.group_by
  end

  test "count() by <field> groups into one series per distinct value" do
    p = plan("| count() by to_user")

    assert_equal :count, p.aggregate
    assert_nil p.distinct_field
    assert_equal "to_user", p.group_by
  end

  test "count(distinct <field>) captures the distinct field, no group" do
    p = plan("| count(distinct corr_id)")

    assert_equal :count, p.aggregate
    assert_equal "corr_id", p.distinct_field
    assert_nil p.group_by
  end

  test "count(distinct X) by Y — distinct and by are orthogonal and combine" do
    p = plan("| count(distinct corr_id) by to_user")

    assert_equal :count, p.aggregate
    assert_equal "corr_id", p.distinct_field
    assert_equal "to_user", p.group_by
  end

  test "the full pipeline: filter | count() by field | sort desc | limit N" do
    p = plan("@to_user like /5511/ | count() by to_user | sort desc | limit 100")

    assert_equal "(@to_user like /5511/)", p.filter
    assert_equal :count, p.aggregate
    assert_equal "to_user", p.group_by
    assert_equal :value, p.sort_field, "bare sort orders by the aggregated value"
    assert_equal :desc, p.sort_dir
    assert_equal 100, p.limit
    assert p.valid?
  end

  test "sort by <field> asc captures the field + direction" do
    p = plan("| count() by to_user | sort by cseq asc")

    assert_equal "cseq", p.sort_field
    assert_equal :asc, p.sort_dir
  end

  test "sort defaults to desc; direction is optional" do
    assert_equal :desc, plan("| count() | sort").sort_dir
    assert_equal :desc, plan("| count() | sort by to_user").sort_dir
  end

  test "a bare `count` is accepted as `count()` (backward-compat)" do
    p = plan("| count by to_user")

    assert_equal :count, p.aggregate
    assert_equal "to_user", p.group_by
  end

  test "a leading @ on the group/distinct/sort field is stripped" do
    p = plan("| count(distinct @corr_id) by @to_user | sort by @cseq desc")

    assert_equal "corr_id", p.distinct_field
    assert_equal "to_user", p.group_by
    assert_equal "cseq", p.sort_field
  end

  test "a `|` inside a regex does NOT split the pipeline" do
    p = plan("@message like /INVITE|BYE/ | count() by to_user")

    assert_equal "(@message like /INVITE|BYE/)", p.filter, "the regex (with its |) survives intact"
    assert_equal :count, p.aggregate
    assert_equal "to_user", p.group_by
  end

  test "multiple filter stages AND-join, each parenthesized" do
    p = plan("@to_user like /5511/ | @response_code = 200 | count()")

    assert_equal "(@to_user like /5511/) and (@response_code = 200)", p.filter
    assert_equal :count, p.aggregate
  end

  test "limit N is captured as an integer" do
    assert_equal 25, plan("| count() | limit 25").limit
    assert_nil plan("| count()").limit, "no limit ⇒ all groups"
  end

  test "a malformed aggregation degrades softly (error set, filter kept)" do
    p = plan("@to_user like /5511/ | count(foo)")

    assert_not p.valid?
    assert_includes p.error, "aggregation"
    assert_equal "(@to_user like /5511/)", p.filter, "the filter is still usable"
  end

  test "count(distinct) demands a field" do
    assert_not plan("| count(distinct)").valid?
  end
end
