# frozen_string_literal: true

require "openssl"
require "securerandom"

module Voodu
  # Signature — proving we hold a PAT without ever sending it.
  #
  # The PAT used to ride in every request as `Authorization: Bearer`, so a
  # single intercepted request was total control of that controller: deploy,
  # exec, logs. On a private network that is tolerable. Across the internet,
  # which is what the hosted SaaS does, it is not.
  #
  # So the secret stops travelling. Each request carries an HMAC over what the
  # request IS — method, path, query, body, and a timestamp and nonce that make
  # it good once. Capture it and you have that one request, for a few minutes,
  # and no way to turn a read into a restart.
  #
  # THE KEY COSTS NOTHING, which is why this shape was chosen. The client holds
  # the plain PAT and can hash it; the controller already stores exactly that
  # hash (PAT.HashHex). Both sides can compute the key, and no PAT has to be
  # re-issued.
  #
  # This protects the CREDENTIAL, not the content: bodies and responses still
  # travel in the clear. Only TLS fixes that.
  #
  # Verified byte-for-byte against the Go implementation in
  # gems/poller/src/client/signature.go — see the shared vector in the tests.
  # Two languages agreeing on query encoding is the part that breaks, and it
  # breaks as an intermittent 401 that gets blamed on the network.
  module Signature
    SCHEME = "Voodu"
    VERSION = "v1"

    # Somebody else's clock is not ours to trust to the second. Same leeway the
    # licence verifier uses.
    SKEW = 300

    module_function

    # sign — the header value for one request.
    def header(pat:, method:, path:, query: nil, body: nil, now: Time.now, nonce: SecureRandom.hex(16))
      id = pat_id(pat)
      ts = now.to_i.to_s
      canonical = canonical_string(method: method, path: path, query: query, body: body, ts: ts, nonce: nonce)

      "#{SCHEME} id=#{id}, ts=#{ts}, nonce=#{nonce}, sig=#{sign(key_for(pat), canonical)}"
    end

    # The key is the PAT's sha256 as a 64-char lowercase hex STRING, hashed as
    # its UTF-8 bytes rather than the decoded digest. "Decode it first" is one
    # more thing two languages can disagree about, and this one is free to
    # verify: it is the same string the controller has on disk.
    def key_for(pat) = OpenSSL::Digest::SHA256.hexdigest(pat.to_s)

    def sign(key, canonical)
      digest = OpenSSL::HMAC.digest("SHA256", key, canonical)

      Base64.urlsafe_encode64(digest, padding: false)
    end

    # The token is `pat_` + 28 base64url characters; the first 6 of those are
    # the public ID the controller keys its record by. Mirrors ParsePATToken in
    # internal/controller/pat.go — including the length and alphabet checks,
    # because sending an id the controller will reject is a 401 with no
    # explanation rather than a clean local failure.
    TOKEN_PREFIX = "pat_"
    TOKEN_BODY_LEN = 28
    TOKEN_ID_LEN = 6
    TOKEN_ALPHABET = /\A[A-Za-z0-9_-]+\z/

    def pat_id(pat)
      body = pat.to_s.delete_prefix(TOKEN_PREFIX)
      return "" unless pat.to_s.start_with?(TOKEN_PREFIX)
      return "" unless body.length == TOKEN_BODY_LEN && TOKEN_ALPHABET.match?(body)

      body[0, TOKEN_ID_LEN]
    end

    # Newline-joined, no trailing newline. Every field is fixed-position, so a
    # value containing a newline cannot shift the meaning of the next one — the
    # method, timestamp and nonce cannot contain one, and path and query are
    # percent-encoded before they get here.
    def canonical_string(method:, path:, ts:, nonce:, query: nil, body: nil)
      [
        VERSION,
        method.to_s.upcase,
        path.to_s,
        canonical_query(query),
        OpenSSL::Digest::SHA256.hexdigest(body.to_s),
        ts.to_s,
        nonce.to_s
      ].join("\n")
    end

    # Sorted by name then value, each side percent-encoded with RFC 3986
    # unreserved characters left alone, joined `k=v` with `&`.
    #
    # Specified rather than delegated to whatever the HTTP library does,
    # because this is exactly where two languages drift: Ruby escapes a space
    # as `+` in one API and `%20` in another, and Go's url.Values sorts by key
    # but not by value for repeated keys.
    def canonical_query(query)
      pairs = normalise_query(query)
      return "" if pairs.empty?

      pairs
        .map { |k, v| [escape(k), escape(v)] }
        .sort
        .map { |k, v| "#{k}=#{v}" }
        .join("&")
    end

    def normalise_query(query)
      case query
      when nil, "" then []
      when Hash then query.flat_map { |k, v| Array(v).map { |one| [k.to_s, one.to_s] } }
      when String then URI.decode_www_form(query).map { |k, v| [k.to_s, v.to_s] }
      else []
      end
    end

    # CGI.escape turns a space into `+`; RFC 3986 wants `%20`. Everything the
    # PAT plane sends is ASCII, but relying on that is how the first non-ASCII
    # pod name becomes a 401.
    def escape(value) = ERB::Util.url_encode(value.to_s)
  end
end
