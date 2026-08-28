# frozen_string_literal: true

require "test_helper"

class ServerTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  # Names are unique per org, not globally. A global index answers "has already
  # been taken" for a name only another tenant uses — an enumeration oracle —
  # and stops two customers from both running a box called "web-1".
  test "the same server name is allowed in a different org" do
    duplicate = orgs(:globex).servers.new(
      name: servers(:alpha).name, endpoint: "http://10.9.9.9:8687", pat: "pat-x"
    )

    assert duplicate.valid?, duplicate.errors.full_messages.to_sentence
  end

  test "the same server name still collides inside one org" do
    duplicate = orgs(:acme).servers.new(
      name: servers(:alpha).name, endpoint: "http://10.9.9.9:8687", pat: "pat-x"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end
end
