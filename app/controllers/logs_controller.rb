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
    render Views::Logs::Show.new(
      **dashboard_context.merge(updated_at: Time.current, pod_name: params[:name])
    )
  end

  # stream — single-pod tail. Proxies /api/pat/v1/pods/:name/logs.
  def stream
    return write_no_island if voodu_client.nil?

    set_stream_headers

    voodu_client.logs_stream(params[:name], follow: follow_param, tail: tail_param) do |chunk|
      response.stream.write(chunk)
    end
  rescue Voodu::Client::Error => e
    safe_write("\n[stream error] #{e.message}\n")
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
    safe_write("\n[stream error] #{e.message}\n")
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

  def safe_write(text)
    response.stream.write(text)
  rescue IOError, ActionController::Live::ClientDisconnected
  end
end
