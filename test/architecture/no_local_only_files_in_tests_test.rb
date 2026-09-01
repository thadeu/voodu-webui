# frozen_string_literal: true

require "test_helper"

# No test opens a file that only exists on a developer's machine.
#
# The suite is green locally and red in CI, on code nobody touched, for a
# reason the failure does not name — and the fix is always "oh, that file is
# gitignored". It has now happened twice in this repository:
#
#   config/license/private_key.pem   two tests signed plan licences with the
#                                    REAL key, which is gitignored precisely
#                                    so it never leaves the machine that
#                                    holds it. Errno::ENOENT in CI.
#   .env                             loaded in the test environment too, and
#                                    AuthSettings reads ENV directly, so a
#                                    working .env turned 13 unrelated tests
#                                    red. Fixed in config/environments/test.rb.
#
# The second one cannot recur; this stops the first. A gate that fails only in
# CI is a gate people learn to ignore, so this fails on the machine where the
# mistake is made.
class NoLocalOnlyFilesInTestsTest < ActiveSupport::TestCase
  # Paths that are absent from a clean checkout on purpose. test/fixtures/files
  # holds the committed stand-ins.
  LOCAL_ONLY = %r{config/license/[^"']*\.(?:pem|jwt)}

  # READING one, not mentioning it. no_private_keys_test names the same path to
  # assert it is gitignored, which is the opposite of the mistake — a rule that
  # cannot tell those apart is a rule that gets deleted.
  READS = /\.read\b|File\.(?:read|open|binread)|IO\.read/

  test "no test file reads something a clean checkout does not have" do
    offenders = Dir[Rails.root.join("test/**/*.rb")].flat_map { |path|
      relative = Pathname(path).relative_path_from(Rails.root)
      next [] if relative.to_s == "test/architecture/no_local_only_files_in_tests_test.rb"

      Pathname(path).read.each_line.with_index(1).filter_map do |line, number|
        next if line.strip.start_with?("#")
        next unless LOCAL_ONLY.match?(line) && READS.match?(line)

        "#{relative}:#{number}: #{line.strip}"
      end
    }

    assert_empty offenders,
      "these exist on the machine that wrote them and nowhere else — sign with " \
      "test/fixtures/files/license_test_private_key.pem and point LicenseToken " \
      "at the matching public half, the way license_activation_test does"
  end

  # The stand-ins the message above points at have to actually be there.
  test "the committed test keypair exists" do
    %w[license_test_private_key.pem license_test_public_key.pem].each do |name|
      assert_path_exists Rails.root.join("test/fixtures/files", name)
    end
  end
end
