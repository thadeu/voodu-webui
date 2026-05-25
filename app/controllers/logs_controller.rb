# frozen_string_literal: true

# LogsController — live tail viewer + streaming proxy.
#
#   GET /logs                  → multi-source viewer page (every pod)
#   GET /logs/:name            → single-pod viewer page
#   GET /logs/stream           → chunked text/plain proxy of
#                                /api/pat/v1/logs (server-side fan-out
#                                across every pod, lines prefixed with
#                                [pod-name])
#   GET /logs/:name/stream     → chunked text/plain proxy of
#                                /api/pat/v1/pods/:name/logs (one pod)
#
# ActionController::Live for the streaming proxies. The HTML actions
# (index, show) don't touch `response.stream`, so they keep the
# normal request lifecycle — only the stream actions flip to live.
class LogsController < ApplicationController
  include ActionController::Live

  def index
    render Views::Logs::Index.new(
      **dashboard_context.merge(
        updated_at: Time.current,
        pods:       pods_for_picker
      )
    )
  end

  def show
    view = Views::Logs::Show.new(
      **dashboard_context.merge(
        updated_at:  Time.current,
        pod_name:    params[:name],
        drawer:      drawer_embed?,
        pods:        drawer_embed? ? [] : pods_for_picker,
        back_to_pod: came_from_pod_page?(params[:name])
      )
    )

    # In embed mode skip the Rails layout entirely — the drawer's
    # injectHTML expects bare body markup (no <html>/<head>/etc).
    drawer_embed? ? render(view, layout: false) : render(view)
  end

  # stream — single-pod tail. Proxies /api/pat/v1/pods/:name/logs.
  #
  # Error handling philosophy:
  #   We DON'T write the upstream error inline as a fake log line —
  #   that surfaced in the operator's feed as `[stream error] Net::
  #   ReadTimeout` polluting the log view. Instead we log it server-
  #   side (Rails.logger) and close the stream cleanly. The Stimulus
  #   log-stream controller handles the EOF by surfacing a "stream
  #   broke" toast + offering to reconnect; that's the right UX
  #   layer for connection failures, not the log buffer itself.
  def stream
    return write_no_island if voodu_client.nil?

    set_stream_headers

    # Release the dependency interlock during the blocking proxy
    # loop. Without this, an open SSE tab holds a reader on the
    # Rails reloader for as long as the stream lives, which means
    # the operator's next code edit can't acquire the write lock
    # to reload — they observe "I changed code and it didn't take
    # effect" and restart bin/dev. permit_concurrent_loads is the
    # canonical Rails answer for ActionController::Live actions
    # that spend most of their time in blocking IO. We promise not
    # to autoload any constants inside this block (we don't — the
    # client + chunk yield are already loaded).
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
      voodu_client.logs_stream(params[:name], follow: follow_param, tail: tail_param) do |chunk|
        response.stream.write(chunk)
      end
    end
  rescue Voodu::Client::Error => e
    Rails.logger.warn("logs#stream: #{e.class} #{e.message}")
  rescue ActionController::Live::ClientDisconnected
    # Browser closed the tab / navigated away. Normal teardown.
  ensure
    response.stream.close
  end

  # stream_all — multi-pod tail. Proxies /api/pat/v1/logs (server-side
  # fan-out). Optional scope/kind/name query params filter the pool
  # the same way they do on /pods.
  def stream_all
    return write_no_island if voodu_client.nil?

    set_stream_headers

    # Same interlock release as `stream` — see the long comment there
    # for the dev-reloader rationale.
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
      voodu_client.logs_stream_multi(
        follow: follow_param,
        tail:   tail_param,
        scope:  params[:scope],
        kind:   params[:kind],
        name:   params[:name]
      ) do |chunk|
        response.stream.write(chunk)
      end
    end
  rescue Voodu::Client::Error => e
    Rails.logger.warn("logs#stream_all: #{e.class} #{e.message}")
  rescue ActionController::Live::ClientDisconnected
  ensure
    response.stream.close
  end

  private

  # pods_for_picker — compact pod list for the PodPicker dropdown.
  # Delegates to IslandPods.compact so Metrics + Logs share one
  # cache cell (avoids double round-trips when the operator
  # bounces between the two surfaces).
  def pods_for_picker
    IslandPods.compact(voodu_client, current_island)
  end

  # came_from_pod_page? — true when the Referer header points at the
  # pod detail page for THIS pod (the "View logs" button on the
  # pod's header is the only edge that leads here that way). Used
  # to decide whether to render the "← Back to pod" affordance.
  #
  # When the operator arrives via the in-page picker dropdown
  # (Logs index → select pod), the Referer is /<key>/logs or
  # /<key>/logs/<other-name> — the back-link would either redirect
  # to /pods/<name> the operator wasn't on, or feel like a dead-end.
  # So we suppress it.
  #
  # Referer can be missing (privacy extensions, manual URL paste,
  # opening from another origin) — in that case we conservatively
  # hide the link too, since there's no proven "back" context.
  def came_from_pod_page?(pod_name)
    ref = request.referer.to_s
    return false if ref.blank? || pod_name.blank?

    URI.parse(ref).path.match?(%r{\A/[^/]+/pods/#{Regexp.escape(pod_name)}\z})
  rescue URI::InvalidURIError
    false
  end

  def set_stream_headers
    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["Cache-Control"]     = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
  end

  def follow_param
    params[:follow] != "false"
  end

  def tail_param
    (params[:tail].presence || "20").to_i
  end

  def write_no_island
    response.headers["Content-Type"] = "text/plain"
    response.status = 503
    response.stream.write("no island selected\n")
    response.stream.close
  end

  # safe_write — defensive shim around response.stream.write that
  # swallows the two normal disconnect errors. Kept in case future
  # branches need to write a status message at teardown.
  def safe_write(text)
    response.stream.write(text)
  rescue IOError, ActionController::Live::ClientDisconnected
  end
end
