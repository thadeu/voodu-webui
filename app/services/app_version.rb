# frozen_string_literal: true

# AppVersion — which build of the dashboard this is.
#
# Baked in at image build time from the git tag that triggered the release
# (Dockerfile ARG → ENV, set by .github/workflows/release.yml). Read at runtime
# rather than resolved from git, because the image has no .git directory and
# shelling out for a version on a container that may be minutes from an
# incident is the wrong trade.
#
# Outside a release build there is no tag to bake, so it says so. "dev" is more
# honest than a stale number, and an operator reporting a bug from a build that
# calls itself dev has told us something true.
class AppVersion
  DEV = "dev"

  def self.current
    tag = ENV["APP_VERSION"].to_s.strip

    return DEV if tag.empty?

    # The workflow passes the ref name, which carries the `v`. Everything else
    # in the UI writes versions without it.
    tag.delete_prefix("v")
  end

  def self.released? = current != DEV
end
