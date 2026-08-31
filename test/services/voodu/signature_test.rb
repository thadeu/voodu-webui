# frozen_string_literal: true

require "test_helper"

# The PAT stops travelling.
#
# It used to ride in every request as `Authorization: Bearer`, so one
# intercepted request was total control of that controller. Now the request
# carries a proof instead, and the tests that matter are the ones saying what a
# capturer cannot do with it.
class Voodu::SignatureTest < ActiveSupport::TestCase
  # The same vector is pinned in two other implementations — the Go poller
  # (gems/poller/src/client/signature.go) and the controller
  # (clowk-voodu internal/controller/pat_signature_test.go). Three languages
  # agreeing is the whole point: two of them drifting on query encoding shows
  # up as an intermittent 401 that gets blamed on the network.
  PAT = "pat_Ab3-_xYz01234567890123456789"
  TS = 1_788_000_000
  NONCE = "0" * 32

  test "the vector for a plain GET" do
    header = Voodu::Signature.header(
      pat: PAT, method: :get, path: "/api/pat/v1/pods", now: Time.at(TS), nonce: NONCE
    )

    assert_equal "Voodu id=Ab3-_x, ts=#{TS}, nonce=#{NONCE}, " \
                 "sig=4sepjmSvGAV5neJHO_ABgV80oodUrAfMdyaCb2IEQYE", header
  end

  test "the vector with a query and a body" do
    header = Voodu::Signature.header(
      pat: PAT, method: :post, path: "/api/pat/v1/pods/web-1/restart",
      query: {"scope" => "fsw", "since" => "a b"}, body: '{"force":true}',
      now: Time.at(TS), nonce: "0123456789abcdef0123456789abcdef"
    )

    assert_includes header, "sig=P_JpjmCtmcQ2_04vWEldQoqU9uIZ_Z4U75LT4jbyi5A"
  end

  # Where Ruby and Go part company: CGI.escape spells a space `+`, RFC 3986
  # wants `%20`, and only one of them matches the controller.
  test "a space in a query value is percent-encoded, not plus" do
    assert_equal "since=a%20b", Voodu::Signature.canonical_query({"since" => "a b"})
  end

  test "repeated values are sorted, not left in insertion order" do
    query = {"pod" => ["web-2", "web-1"], "a" => "1"}

    assert_equal "a=1&pod=web-1&pod=web-2", Voodu::Signature.canonical_query(query)
  end

  test "a query given as a string canonicalises the same as a hash" do
    from_string = Voodu::Signature.canonical_query("since=a+b&scope=fsw")
    from_hash = Voodu::Signature.canonical_query({"scope" => "fsw", "since" => "a b"})

    assert_equal from_hash, from_string
  end

  # ── What a capturer cannot do ──────────────────────────────────────────

  test "the PAT never appears in the header" do
    header = Voodu::Signature.header(pat: PAT, method: :get, path: "/api/pat/v1/pods")

    assert_not_includes header, PAT
    assert_not_includes header, PAT.delete_prefix("pat_")
  end

  test "changing the method changes the signature" do
    a = Voodu::Signature.header(pat: PAT, method: :get, path: "/x", now: Time.at(TS), nonce: NONCE)
    b = Voodu::Signature.header(pat: PAT, method: :post, path: "/x", now: Time.at(TS), nonce: NONCE)

    assert_not_equal a, b, "a captured read could be replayed as a write"
  end

  test "changing the path changes the signature" do
    a = Voodu::Signature.header(pat: PAT, method: :post, path: "/api/pat/v1/pods/web-1/restart",
      now: Time.at(TS), nonce: NONCE)
    b = Voodu::Signature.header(pat: PAT, method: :post, path: "/api/pat/v1/pods/db-1/restart",
      now: Time.at(TS), nonce: NONCE)

    assert_not_equal a, b, "a captured restart could be aimed at another pod"
  end

  test "changing the body changes the signature" do
    a = Voodu::Signature.header(pat: PAT, method: :post, path: "/x", body: "{}", now: Time.at(TS), nonce: NONCE)
    b = Voodu::Signature.header(pat: PAT, method: :post, path: "/x", body: "{\"a\":1}", now: Time.at(TS), nonce: NONCE)

    assert_not_equal a, b
  end

  test "the key is the PAT's sha256, which is what the controller stores" do
    assert_equal OpenSSL::Digest::SHA256.hexdigest(PAT), Voodu::Signature.key_for(PAT)
  end

  # Mirrors ParsePATToken: `pat_` + exactly 28 base64url chars, id = first 6.
  test "the id is only extracted from a well-formed token" do
    assert_equal "Ab3-_x", Voodu::Signature.pat_id(PAT)
    assert_equal "", Voodu::Signature.pat_id("pat-alpha-secret")
    assert_equal "", Voodu::Signature.pat_id("pat_tooshort")
    assert_equal "", Voodu::Signature.pat_id("pat_#{"!" * 28}")
    assert_equal "", Voodu::Signature.pat_id(nil)
  end

  test "each call gets its own nonce" do
    nonces = 5.times.map { Voodu::Signature.header(pat: PAT, method: :get, path: "/x")[/nonce=(\h+)/, 1] }

    assert_equal 5, nonces.uniq.size, "a repeated nonce is a replay the controller will refuse"
  end
end
