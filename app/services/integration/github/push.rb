# frozen_string_literal: true

# Integration::Github::Push — the facts worth keeping out of a push payload.
#
# GitHub sends a lot. Most of it is URL templates for endpoints we never call,
# and the whole body is already stored on the receipt as evidence — so this is
# not about saving space. It is about deciding, ONCE and in one place, which
# fields the product is allowed to show.
#
# ## What is deliberately NOT taken
#
# EMAIL ADDRESSES. `pusher.email`, `commits[].author.email` and
# `repository.owner.email` are all in the payload, and none of them answers a
# question an operator has. Storing the raw body as evidence is one act;
# putting somebody's address on a dashboard for every colleague to read is a
# different one, and it is the kind of thing that is easy to add and awkward to
# take back.
#
# The login and the avatar say who pushed. That is the whole question.
class Integration::Github::Push
  def initialize(payload)
    @payload = payload.is_a?(Hash) ? payload : {}
  end

  # facts — a flat hash for `details`, with nothing nil in it.
  #
  # Flat because it is read by a screen, not by code that walks it: a row wants
  # "the avatar" without knowing whether GitHub nests it under `sender` or
  # `pusher` this year.
  def facts
    {
      "sender" => sender_login,
      "sender_avatar" => sender_avatar,
      "sender_url" => sender_url,
      "commit_message" => commit_message,
      "commit_url" => commit_url,
      "compare_url" => compare_url,
      "changed_files" => changed_files,
      "changed_paths" => changed_paths,
      "committed_at" => committed_at
    }.compact
  end

  # `sender` and not `pusher`: they differ, and the difference matters. A merge
  # from the GitHub UI has the person who clicked as `sender` and the branch's
  # author as `pusher`; an automation has the app as sender. The sender is who
  # caused THIS delivery, which is what a deploy log is about.
  def sender_login = dig("sender", "login")

  def sender_avatar = dig("sender", "avatar_url")

  def sender_url = dig("sender", "html_url")

  # The subject line only. A commit body can be a page long, and a row that
  # renders one is a row that stops being a row.
  def commit_message = dig("head_commit", "message").to_s.lines.first&.strip.presence

  def commit_url = dig("head_commit", "url")

  # The diff between what the box had and what arrived — the single most useful
  # link on a deployment, and GitHub hands it over rather than making us build
  # it from two SHAs.
  def compare_url = @payload["compare"].presence

  # How much this push touched, which is what makes "why did this fire" and
  # "why did this NOT fire" answerable against the trigger's watched paths.
  def changed_files
    head = @payload["head_commit"]

    return nil unless head.is_a?(Hash)

    total = %w[added removed modified].sum { |k| Array(head[k]).size }

    total.positive? ? total : nil
  end

  # The files the whole push touched, across every commit in it, for the
  # box to hold against a trigger file's `on.push.paths`. Nil means "we
  # cannot say", and the box then fires every file that matches the ref —
  # the right default, because a deploy that did not happen is the worse
  # mistake. That happens when the payload carries no commits (a tag push,
  # an empty force-push) or when GitHub cut the list: the `commits` array
  # stops at PAYLOAD_COMMIT_CAP and says nothing about what it dropped.
  PAYLOAD_COMMIT_CAP = 2_048

  def changed_paths
    commits = @payload["commits"]

    return nil unless commits.is_a?(Array) && commits.any?
    return nil if commits.size >= PAYLOAD_COMMIT_CAP

    paths = commits.flat_map do |commit|
      next [] unless commit.is_a?(Hash)

      %w[added removed modified].flat_map { |k| Array(commit[k]) }
    end

    paths.map(&:to_s).reject(&:empty?).uniq.sort
  end

  def committed_at = dig("head_commit", "timestamp")

  private

  def dig(*path)
    value = @payload.dig(*path)

    value.is_a?(String) ? value.presence : value
  end
end
