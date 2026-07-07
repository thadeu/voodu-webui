# frozen_string_literal: true

require "test_helper"

# WebTime.zone_name resolution: the current org's timezone when set to a zone
# ActiveSupport recognises, else UTC. Corrupt data degrades to UTC, it never
# crashes a render. Timezone is a per-org preference — there is no global
# fallback (org-less pages simply render in UTC).
class WebTimeTest < ActiveSupport::TestCase
  fixtures :orgs

  setup { WebTime.clear_request_cache }

  teardown do
    Current.reset
    WebTime.clear_request_cache
  end

  test "renders in the current org's timezone" do
    orgs(:acme).update!(timezone: "America/Sao_Paulo")

    Current.set(org: orgs(:acme)) do
      WebTime.clear_request_cache

      assert_equal "America/Sao_Paulo", WebTime.zone_name
    end
  end

  test "an org with no timezone renders in UTC" do
    orgs(:acme).update!(timezone: nil)

    Current.set(org: orgs(:acme)) do
      WebTime.clear_request_cache

      assert_equal "UTC", WebTime.zone_name
    end
  end

  test "a corrupt org timezone (bypassing validation) degrades to UTC" do
    orgs(:acme).update_column(:timezone, "Mars/Phobos")

    Current.set(org: orgs(:acme)) do
      WebTime.clear_request_cache

      assert_equal "UTC", WebTime.zone_name
    end
  end

  test "an org-less request renders in UTC" do
    Current.set(org: nil) do
      WebTime.clear_request_cache

      assert_equal "UTC", WebTime.zone_name
    end
  end
end
