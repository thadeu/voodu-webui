# frozen_string_literal: true

require "test_helper"

# No signing key reaches git.
#
# .gitignore stops the accident; this stops the rest. A pattern can be edited, a
# file renamed out from under it, and `git add -f` ignores it entirely — and the
# consequence is not a leaked config value: whoever holds the licence signing
# key issues their own licences, forever, including after the leak is noticed.
# Rotating means shipping a new public key in a new image, which invalidates
# every licence already sold.
#
# The test keypair under test/fixtures is deliberately exempt and deliberately
# named: it exists so the suite can mint tokens, it signs nothing real, and its
# public half is not the one in the image.
class NoPrivateKeysTest < ActiveSupport::TestCase
  HEADER = /-----BEGIN (?:RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY-----/
  ALLOWED = %r{\Atest/fixtures/files/license_test_private_key\.pem\z}

  test "no private key is tracked by git" do
    tracked = `git ls-files -z`.split("\0")
    offenders = tracked.reject { |path| ALLOWED.match?(path) }.select do |path|
      full = Rails.root.join(path)
      next false unless File.file?(full) && File.size(full) < 200_000

      File.read(full, encoding: "BINARY").match?(HEADER)
    rescue ArgumentError
      false
    end

    assert_empty offenders,
      "a private key is committed: #{offenders.join(", ")}. Remove it, rotate it, and " \
      "assume it is compromised — git history keeps it even after a delete."
  end

  # The signing key belongs beside the public one so it is easy to find and hard
  # to lose; the pattern is what keeps it out of git.
  test "the licence key directory ignores anything named private" do
    ignored = system("git check-ignore -q config/license/private_key.pem")

    assert ignored, "config/license/private_key.pem is not gitignored"
  end

  # The image is PUBLISHED. The Dockerfile does `COPY . .`, so anything the
  # build context can see ends up in a registry anyone can pull — and a copy of
  # the signing key there hands every customer the ability to mint their own
  # licences, against a public half shipping in the same image, so rotating
  # would invalidate everything already sold.
  #
  # Verified by removing the line and rebuilding: the key appears in the context.
  test "the signing key is kept out of the Docker build context" do
    patterns = Rails.root.join(".dockerignore").read.lines.map(&:strip)

    assert_includes patterns, "/config/license/*private*",
      ".dockerignore no longer excludes the signing key — it would ship in the image"
  end
end
