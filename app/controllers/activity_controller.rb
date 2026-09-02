# frozen_string_literal: true

# ActivityController — the /activity page: what was DONE to this server.
#
# Per-server rather than org-level, and that is not an accident of routing: an
# action happens to one box. The trail names config keys, file paths and
# resource names belonging to that box, so it belongs behind the same door the
# operator already used to reach its pods and logs.
#
# No capability gate, matching Logs. Somebody who can read this server's logs
# already sees production stdout; refusing them the list of applies that
# produced it would be a lock on the smaller of the two.
#
# Dual-mode like Metrics and Alerts: a Turbo-Frame request re-renders ONLY the
# table body with layout: false, so a running action resolves itself without
# the operator reloading and without repainting the chrome.
class ActivityController < ApplicationController
  FRAME = "activity-table"

  def index
    data = ActivityPageData.new(current_server, filter_params) if current_server

    if request.headers["Turbo-Frame"] == FRAME
      render Views::Activity::Frame.new(data: data), layout: false
    else
      render Views::Activity::Index.new(**dashboard_context.merge(data: data))
    end
  end

  private

  # filter_params — read out by hand rather than through `permit`.
  #
  # Strong parameters exist to stop mass assignment; nothing here is assigned
  # to anything. What it would cost is real: `permit(act: [])` accepts ONLY an
  # array, so `?act=apply` — the shareable single-value URL the filter chips
  # produce — is silently dropped, and the page answers as if no filter had
  # been asked for. Declaring both forms is fragile; reading the value is not.
  #
  # Every value is intersected against a fixed vocabulary in ActivityPageData,
  # so nothing that arrives here reaches a query unchecked.
  #
  # The action filter rides on `act`, NOT `action`: Rails writes the controller
  # action name into params[:action] from the route, so a query parameter by
  # that name never survives to be read.
  def filter_params
    {
      scope: params[:scope],
      q: params[:q],
      # range, from and until travel TOGETHER. Reading `range` without its
      # bounds is worse than reading neither: `range=custom` arrives, the
      # window falls back to its default, and the picker looks broken while
      # reporting the dates the operator chose.
      range: params[:range],
      from: params[:from],
      until: params[:until],
      # No page number: this list is paged by a row boundary. See
      # ActivityPageData#rows for why offset is wrong for a list that grows at
      # the top while you read it.
      before: params[:before],
      after: params[:after],
      act: multi(:act),
      origin: multi(:origin),
      status: multi(:status)
    }
  end

  # multi accepts both `?act=apply&act=restart` (a checkbox group) and
  # `?act=apply,restart` (a link somebody shared). Anything else — a nested
  # hash from a hand-mangled URL — degrades to a string that matches nothing.
  def multi(key)
    raw = params[key]

    raw.is_a?(Array) ? raw.map(&:to_s) : raw.to_s
  end
end
