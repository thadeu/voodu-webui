# frozen_string_literal: true

require "test_helper"

# Org — the server/grouping layer. Scenarios: identity (uuidv7 + short_id),
# name required/unique, the delete guard (can't orphan servers), and that a
# server must belong to an org.
class OrgTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  test "a new org gets a uuidv7 id and an 8-char base62 short_id used as the param" do
    org = Org.create!(name: "New Co")

    assert_equal 36, org.id.length
    assert_equal "7", org.id[14], "id should be a v7 uuid (version nibble = 7)"
    assert_match(/\A[a-zA-Z0-9]{8}\z/, org.short_id)
    assert_equal org.short_id, org.to_param
  end

  test "name is required" do
    assert Org.new(name: "").invalid?
  end

  test "name is unique" do
    dup = Org.new(name: orgs(:acme).name)

    assert dup.invalid?
    assert_includes dup.errors[:name], "has already been taken"
  end

  test "an org that still owns servers cannot be deleted" do
    org = orgs(:acme) # owns alpha + beta

    assert_not org.destroy
    assert_includes org.errors[:base].join, "servers"
    assert Org.exists?(org.id)
  end

  test "an org with no servers can be deleted" do
    org = orgs(:voidco) # owns nothing (globex owns gamma)

    assert org.destroy
    assert_not Org.exists?(org.id)
  end

  test "a server must belong to an org" do
    server = Server.new(name: "orphan", endpoint: "http://10.0.0.9:8687", pat: "x")

    assert server.invalid?
    assert_includes server.errors[:org].join, "must exist"
  end
end
