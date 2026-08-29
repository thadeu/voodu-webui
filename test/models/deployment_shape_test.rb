# frozen_string_literal: true

require "test_helper"

# The shape of the deployment, asserted rather than assumed.
#
# One image serves two deployments, and the split between them is a single
# rule: DATABASE_URL moves the PRIMARY to Postgres, and moves nothing else.
# The warehouse stays on SQLite in both, because it is built on ground only
# SQLite has — 11 generated columns, json_extract, strftime, REGEXP registered
# through create_function, COLLATE NOCASE. Pointing metrics or hep at Postgres
# would not degrade, it would fail to create the tables at all.
#
# That rule lives in config/database.yml and in the connects_to on
# MetricsRecord / HepRecord, which is three files apart and easy to "tidy up"
# into consistency by someone who does not know why it is inconsistent. This is
# the test that answers them.
#
# CI runs SQLite only, so in CI this asserts the self-hosted half. The Postgres
# half is exercised whenever someone runs the suite with DATABASE_URL set,
# which is the documented way to check that deployment before shipping it.
class DeploymentShapeTest < ActiveSupport::TestCase
  test "the primary follows DATABASE_URL and the warehouse never does" do
    expected = ENV["DATABASE_URL"].presence ? "postgresql" : "sqlite3"

    assert_equal expected, ActiveRecord::Base.connection_db_config.adapter,
      "primary should be #{expected} (DATABASE_URL #{ENV["DATABASE_URL"].presence ? "set" : "unset"})"

    assert_equal "sqlite3", MetricsRecord.connection_pool.db_config.adapter
    assert_equal "sqlite3", HepRecord.connection_pool.db_config.adapter
  end
end
