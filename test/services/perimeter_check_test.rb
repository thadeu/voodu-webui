# frozen_string_literal: true

require "test_helper"

class PerimeterCheckTest < ActiveSupport::TestCase
  test "addresses inside the network say nothing" do
    ["127.0.0.1", "::1", "10.0.0.4", "192.168.105.6", "172.16.3.9", "169.254.1.1"].each do |ip|
      assert_not PerimeterCheck.exposed?(ip), "#{ip} is inside the perimeter"
    end
  end

  test "a public address is exposed" do
    ["54.20.48.217", "8.8.8.8", "2001:4860:4860::8888"].each do |ip|
      assert PerimeterCheck.exposed?(ip), "#{ip} is not a private address"
    end
  end

  # "We could not tell" must never render as "all good".
  test "an unparseable address is treated as exposed" do
    assert PerimeterCheck.exposed?("not-an-ip")
    assert PerimeterCheck.exposed?(nil)
    assert PerimeterCheck.exposed?("")
  end

  test "an operator whose proxy forwards a public client IP can silence it" do
    original = ENV["VOODU_TRUSTED_PERIMETER"]
    ENV["VOODU_TRUSTED_PERIMETER"] = "1"

    assert_not PerimeterCheck.exposed?("8.8.8.8")
  ensure
    ENV["VOODU_TRUSTED_PERIMETER"] = original
  end
end
