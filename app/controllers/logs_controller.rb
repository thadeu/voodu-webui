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
    render Views::Logs::Index.new(**dashboard_context.merge(updated_at: Time.current))
  end

  def show
    view = Views::Logs::Show.new(
      **dashboard_context.merge(
        updated_at: Time.current,
        pod_name:   params[:name],
        drawer:     drawer_embed?
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

    voodu_client.logs_stream(params[:name], follow: follow_param, tail: tail_param) do |chunk|
      response.stream.write(chunk)
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

    voodu_client.logs_stream_multi(
      follow: follow_param,
      tail:   tail_param,
      scope:  params[:scope],
      kind:   params[:kind],
      name:   params[:name]
    ) do |chunk|
      response.stream.write(chunk)
    end
  rescue Voodu::Client::Error => e
    Rails.logger.warn("logs#stream_all: #{e.class} #{e.message}")
  rescue ActionController::Live::ClientDisconnected
  ensure
    response.stream.close
  end

  private

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
