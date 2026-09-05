# frozen_string_literal: true

require "test_helper"

# The onboarding for a repository with no `.voodu/` yet — the screen's only
# teaching moment.
#
# An operator who has just connected a repository and sees "no trigger file"
# has one question, what do I write, and the answer is four lines of YAML they
# will never guess. Most of this file pins the part that makes the answer
# usable: it is about THEIR repository, not a generic snippet they have to
# translate first.
class TriggerExamplesTest < ActiveSupport::TestCase
  def render(repo: "acme/billing-api", branch: "develop")
    ApplicationController.render(
      Components::Deploys::TriggerExamples.new(repo: repo, branch: branch), layout: false
    )
  end

  # A generic `branches: [main]` makes the reader translate before they paste,
  # and translation is where the branch quietly stays wrong.
  test "the example uses the repository's own default branch" do
    html = render(branch: "develop")

    assert_includes html, "branches: [develop]"
    assert_not_includes html, "branches: [main]"
  end

  test "the name is derived from the repository" do
    html = render(repo: "acme/billing-api")

    assert_includes html, "name: Billing Api"
  end

  test "it names the directory the file belongs in" do
    html = render

    assert_includes html, "#{DeploysData::TRIGGER_DIR}/deploy.yml"
  end

  # One shape open, the rest folded. Three YAML blocks stacked is a wall; one
  # plus "there are other shapes" is a starting point.
  test "the variations are folded away" do
    html = render

    assert_includes html, "<details"
    assert_includes html, "Other shapes"

    # And they are there for the reader who opens it.
    assert_includes html, "paths:"
  end

  # `<details>` and not tabs: the fold works with the bundle unloaded, and a
  # reader who wants the simple case never opens it. (The copy buttons inside
  # are Stimulus, and that is fine — they are an extra, not the mechanism.)
  test "the fold needs no javascript" do
    html = render

    fold = html[/<details.*?<\/summary>/m]

    assert_not_nil fold
    assert_not_includes fold, "data-controller"
    assert_not_includes fold, "data-action"
  end

  # Committing the file deploys nothing on its own, and discovering that by
  # pushing and watching nothing happen is the worst way to learn it.
  test "it says the file alone is not enough" do
    html = render

    assert_match(/connected to this server/i, html)
  end

  test "every example can be copied" do
    html = render

    assert_operator html.scan("data-clipboard-value-value").size, :>=, 3
  end
end
