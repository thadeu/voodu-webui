# frozen_string_literal: true

require_relative "lib/poller/version"

Gem::Specification.new do |spec|
  spec.name = "poller"
  spec.version = Poller::VERSION
  spec.authors = ["tadeuu@gmail.com"]
  spec.summary = "Go-based log NDJSON poller"
  spec.description = <<~DESC
    Ships a Go binary that polls multiple voodu controllers in parallel
    over the PAT plane, deduplicates lines, and writes per-pod NDJSON
    files to storage/logs/<server>/<pod>/YYYY-MM-DD.ndjson. The Ruby
    side is a thin Puma::Plugin that spawns / drains the binary, plus a
    Railtie + binstub to make local invocation ergonomic.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir[
    "lib/**/*",
    "bin/*",
    "src/**/*",
    "Makefile",
    "README.md"
  ]

  # No `executables`: there used to be a shell wrapper here that exited 0 when
  # the Go binary was not built, so a fresh checkout "ran" the poller and synced
  # nothing, silently. The binary is built by `make build` (see README) and the
  # Railtie refuses to boot the app without it.
  #
  # No `extensions` either, and not for lack of trying: Bundler installs path
  # gems with `disable_extensions: true` (bundler/source/path.rb), so an
  # extconf here would never run under `bundle install`. A build hook that
  # looks wired up and is not would be the same silence in a new place.
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "puma", ">= 5.0"
end
