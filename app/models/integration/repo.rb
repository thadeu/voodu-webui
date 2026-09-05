# frozen_string_literal: true

# Integration::Repo — one entry in an integration's repository list.
#
# A value object over a hash from `config["repos"]`, not an ActiveRecord. The
# list lives in a jsonb blob because nothing queries it (see the migration),
# but the code reading it should still get names rather than string keys —
# `repo.server_id` beats `entry["server_id"]` at every call site, and a typo in
# the second one is silent.
#
# It carries exactly the bridge the webhook needs: a push names a repository,
# and this says which server and which trigger handle on it.
class Integration::Repo
  ATTRIBUTES = %w[repo server_id trigger_id].freeze

  attr_reader :repo, :server_id, :trigger_id

  def initialize(repo:, server_id:, trigger_id:)
    # Normalised here rather than at the call sites: GitHub compares owner and
    # repository names case-insensitively, and a push that failed to match
    # because somebody typed `Acme/Web` would be debugged as "the webhook is
    # broken".
    @repo = repo.to_s.strip.downcase
    @server_id = server_id.to_i
    @trigger_id = trigger_id.to_s.strip
  end

  def self.from(hash)
    hash = hash.to_h.stringify_keys

    new(
      repo: hash["repo"],
      server_id: hash["server_id"],
      trigger_id: hash["trigger_id"]
    )
  end

  def to_h
    {"repo" => repo, "server_id" => server_id, "trigger_id" => trigger_id}
  end

  # Complete enough to fire a deploy. An entry missing any of the three is not
  # a partial route we could use — it names nothing to call.
  def valid?
    repo.present? && server_id.positive? && trigger_id.present?
  end

  def matches?(other_repo)
    repo == other_repo.to_s.strip.downcase
  end

  def ==(other)
    other.is_a?(self.class) && to_h == other.to_h
  end
  alias_method :eql?, :==

  def hash = to_h.hash
end
