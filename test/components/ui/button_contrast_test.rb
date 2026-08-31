# frozen_string_literal: true

require "test_helper"

# Filled buttons carry white label text, so their background is the only thing
# deciding whether that text can be read.
#
# The chrome accent is not that background. It is tuned to sit BEHIND small
# tinted surfaces — active nav, selected chips, focus rings — where being bright
# is the whole point. Put white text on it and the dark theme measured 1.92:1,
# and the hover state was brighter still, so the label faded further exactly
# when someone reached for it.
#
# These read the compiled stylesheet rather than the component, because the
# component only names a token: what an operator actually sees is whatever that
# token resolved to at build time.
class Components::UI::ButtonContrastTest < ActiveSupport::TestCase
  MINIMUM = 4.5 # WCAG AA, normal text. Button labels here are text-xs.

  # The token DEFINITIONS, not the built bundle: Tailwind minifies its output
  # into one line and reorders it, so parsing :root out of the artefact is
  # brittle in a way that has nothing to do with what is being asserted. The
  # values here are what the bundle copies.
  THEME = Rails.root.join("app/assets/stylesheets/voodu/theme.css")

  def relative_luminance(hex)
    channels = [1, 3, 5].map { |i| hex[i, 2].to_i(16) / 255.0 }
    linear = channels.map { |c| (c <= 0.03928) ? c / 12.92 : (((c + 0.055) / 1.055)**2.4) }

    (0.2126 * linear[0]) + (0.7152 * linear[1]) + (0.0722 * linear[2])
  end

  def contrast(one, two)
    lighter, darker = [relative_luminance(one), relative_luminance(two)].sort.reverse

    (lighter + 0.05) / (darker + 0.05)
  end

  # Dark is the file's :root; the light theme overrides it further down.
  def dark_token(name)
    root = File.read(THEME)[/^:root\s*\{(.*?)^\}/m, 1]

    assert root, "could not find the :root block in #{THEME}"
    root[/--#{Regexp.escape(name)}:\s*(#[0-9a-fA-F]{6})/, 1]
  end

  test "a button label is readable on its own background in the dark theme" do
    on_accent = dark_token("voodu-on-accent") || "#ffffff"

    ["voodu-btn-accent", "voodu-btn-accent-hover"].each do |token|
      background = dark_token(token)

      assert background, "#{token} is not defined in the dark theme"

      measured = contrast(background, on_accent)

      assert measured >= MINIMUM,
        "#{token} (#{background}) against #{on_accent} is #{measured.round(2)}:1, " \
        "below the #{MINIMUM}:1 a label needs"
    end
  end

  # The regression itself: the chrome accent is what this used to be, and it is
  # still nowhere near readable. If someone points a button back at it, this
  # says why that is not a style preference.
  test "the chrome accent remains unfit as a label background" do
    accent = dark_token("voodu-accent")

    assert accent, "the chrome accent is missing"
    assert contrast(accent, "#ffffff") < MINIMUM,
      "the chrome accent now passes for label text — if that was deliberate, " \
      "this test has served its purpose and can go"
  end

  # The sweep. Written against the actual failure mode rather than against the
  # token name: an accent FILL is fine under a toggle track or a 1px hover rail,
  # because nothing is written on top of them. It is only a problem where a
  # label sits on it — `text-voodu-on-accent`, or the filled-button hover idiom.
  #
  # Worth having as a test rather than a habit: the first pass at this was a
  # grep, and the grep missed nine of the twelve, across app/views as well as
  # app/components.
  FILL_UNDER_TEXT = [
    "bg-voodu-accent text-voodu-on-accent",
    "bg-voodu-accent hover:bg-voodu-accent-2",
    "hover:bg-voodu-accent-2"
  ].freeze

  test "no button label sits on the chrome accent, anywhere in the app" do
    offenders = Dir[Rails.root.join("app/**/*.rb")].select do |file|
      body = File.read(file)

      FILL_UNDER_TEXT.any? { |idiom| body.include?(idiom) }
    end

    assert_empty offenders.map { |f| Pathname(f).relative_path_from(Rails.root).to_s },
      "these put label text on the chrome accent, which measures under 2:1 in " \
      "the dark theme — use voodu-btn-accent / voodu-btn-accent-hover"
  end
end
