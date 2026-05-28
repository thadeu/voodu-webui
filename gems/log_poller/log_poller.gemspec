# frozen_string_literal: true

require_relative "lib/log_poller/version"

Gem::Specification.new do |spec|
  spec.name        = "log_poller"
  spec.version     = LogPoller::VERSION
  spec.authors     = ["voodu-webui"]
  spec.summary     = "Go-based log NDJSON poller for voodu islands"
  spec.description = <<~DESC
    Ships a Go binary that polls multiple voodu controllers in parallel
    over the PAT plane, deduplicates lines, and writes per-pod NDJSON
    files to storage/logs/<island>/<pod>/YYYY-MM-DD.ndjson. The Ruby
    side is a thin Puma::Plugin that spawns / drains the binary, plus a
    Railtie + binstub to make local invocation ergonomic.
  DESC
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir[
    "lib/**/*",
    "exe/*",
    "bin/*",
    "src/**/*",
    "Makefile",
    "README.md"
  ]

  spec.bindir       = "exe"
  spec.executables  = ["log-poller"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "puma", ">= 5.0"
end
