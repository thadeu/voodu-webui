# frozen_string_literal: true

require "test_helper"

# Which fields of a push payload the product is allowed to show.
#
# GitHub sends a lot; the whole body is already stored on the receipt as
# evidence, so this class is not about saving space. It is the ONE place that
# decides what reaches a screen — and most of this file is about what it
# refuses.
class Integration::Github::PushTest < ActiveSupport::TestCase
  # Trimmed from a real delivery, so the shape is not my guess.
  PAYLOAD = {
    "ref" => "refs/heads/main",
    "after" => "1a8bfe2b11d6a3d42c701b7b6f45f343a56417b2",
    "compare" => "https://github.com/thadeu/contagorda/compare/421148574097...1a8bfe2b11d6",
    "repository" => {
      "full_name" => "thadeu/contagorda",
      "owner" => {"login" => "thadeu", "email" => "owner@example.com"}
    },
    "pusher" => {"name" => "thadeu", "email" => "pusher@example.com"},
    "sender" => {
      "login" => "thadeu",
      "avatar_url" => "https://avatars.githubusercontent.com/u/77889?v=4",
      "html_url" => "https://github.com/thadeu"
    },
    "head_commit" => {
      "message" => "feat: enhance search\n\nwith a body nobody wants in a row",
      "timestamp" => "2026-09-04T23:40:45-03:00",
      "url" => "https://github.com/thadeu/contagorda/commit/1a8bfe2b11d6",
      "author" => {"name" => "thadeu", "email" => "author@example.com"},
      "added" => ["a.ts"],
      "removed" => [],
      "modified" => ["b.tsx", "c.tsx", "d.tsx"]
    }
  }.freeze

  def facts(payload = PAYLOAD) = Integration::Github::Push.new(payload).facts

  # THE RULE THIS CLASS EXISTS FOR. Three email addresses are in that payload —
  # pusher, commit author, repository owner — and none answers a question an
  # operator has. Storing the raw body as evidence is one act; putting
  # somebody's address on a dashboard for every colleague is a different one.
  test "no email address survives extraction" do
    values = facts.values.map(&:to_s)

    assert_not(values.any? { |v| v.include?("@") },
      "an email reached the extracted facts: #{facts.inspect}")
  end

  # `sender` and not `pusher`: they differ, and the difference matters. A merge
  # from the GitHub UI has the person who clicked as sender and the branch's
  # author as pusher. The sender caused THIS delivery.
  test "the person is the sender" do
    f = facts

    assert_equal "thadeu", f["sender"]
    assert_equal "https://avatars.githubusercontent.com/u/77889?v=4", f["sender_avatar"]
    assert_equal "https://github.com/thadeu", f["sender_url"]
  end

  test "only the commit subject is kept" do
    assert_equal "feat: enhance search", facts["commit_message"]
  end

  # Handed over by GitHub rather than assembled from repo and SHA — a URL we
  # build breaks silently into a 404 the day a path changes.
  test "the commit and compare links come from the payload" do
    f = facts

    assert_equal "https://github.com/thadeu/contagorda/commit/1a8bfe2b11d6", f["commit_url"]
    assert_includes f["compare_url"], "/compare/"
  end

  test "changed files are counted across added, removed and modified" do
    assert_equal 4, facts["changed_files"]
  end

  # An empty payload must yield NO KEYS, not keys holding nil: `details` is
  # read by screens asking `.present?`, and a nil under an expected key reads
  # as "we looked and found nothing" rather than "we never had it".
  test "an empty payload yields no keys at all" do
    assert_empty Integration::Github::Push.new({}).facts
  end

  test "a payload that is not a hash does not raise" do
    assert_empty Integration::Github::Push.new(nil).facts
    assert_empty Integration::Github::Push.new("nope").facts
  end

  test "a push with no file changes reports none rather than zero" do
    payload = PAYLOAD.deep_dup
    payload["head_commit"].merge!("added" => [], "removed" => [], "modified" => [])

    assert_nil facts(payload)["changed_files"]
  end
end
