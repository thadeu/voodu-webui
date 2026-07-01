# frozen_string_literal: true

require "test_helper"

# DataTable::Query compiles the filter DSL into parameterized SQL. These pin
# the shape that matters: like → REGEXP, =/!= → exact, and/or/not compose,
# unknown fields error (never inject), and the value is ALWAYS a bind.
class DataTable::QueryTest < ActiveSupport::TestCase
  RESOLVER = ->(field) { {"method" => "sip_method", "to_user" => "tu", "code" => "response_code"}[field] }

  def compile(query)
    DataTable::Query.compile(query, &RESOLVER)
  end

  test "empty query → no filter" do
    c = compile("   ")

    assert_not c.filter?
    assert_nil c.error
  end

  test "like /re/ compiles to REGEXP with a bind" do
    c = compile("@method like /INVITE/")

    assert_equal "sip_method REGEXP ?", c.sql
    assert_equal ["INVITE"], c.binds
  end

  test "= compiles to an exact case-insensitive match" do
    c = compile("@method = INVITE")

    assert_equal "sip_method = ? COLLATE NOCASE", c.sql
    assert_equal ["INVITE"], c.binds
  end

  test "and / or / not compose into boolean SQL" do
    c = compile("@method like /INVITE/ and not @to_user like /999/")

    assert_equal "(sip_method REGEXP ?) AND (NOT (tu REGEXP ?))", c.sql
    assert_equal %w[INVITE 999], c.binds
  end

  test "an optional leading `filter` keyword is accepted (LogQuery parity)" do
    with = compile("filter @method like /INVITE/")
    without = compile("@method like /INVITE/")

    assert_equal without.sql, with.sql, "`filter @x` compiles the same as `@x`"
    assert_equal ["INVITE"], with.binds
    assert_nil with.error
  end

  test "`filter` is only a clause prefix — as a value it stays literal" do
    c = compile("@method = filter")

    assert_equal "sip_method = ? COLLATE NOCASE", c.sql
    assert_equal ["filter"], c.binds
  end

  test "an unknown field errors out and applies no filter (never injected)" do
    c = compile("@bogus like /x/")

    assert_not c.filter?
    assert_match(/unknown field/, c.error)
  end

  test "a field-less clause is rejected" do
    assert compile("/INVITE/").error.present?
  end

  test "the value is always a bind — SQL injection can't reach the query" do
    c = compile(%q(@to_user = "'; DROP TABLE hep_messages --"))

    assert_equal "tu = ? COLLATE NOCASE", c.sql
    assert_equal ["'; DROP TABLE hep_messages --"], c.binds
  end
end
