# frozen_string_literal: true

# LogsController — live tail viewer + streaming proxy.
#
#   GET /logs                 → multi-source viewer (still mock —
#                               PAT plane has no multi-pod aggregation
#                               endpoint yet)
#   GET /logs/:name           → single-pod viewer; the Stimulus
#                               controller subscribes to /stream below
#   GET /logs/:name/stream    → chunked text/plain proxy that opens
#                               GET /api/pat/v1/pods/:name/logs?follow=true
#                               and forwards every chunk verbatim to
#                               the browser
#
# ActionController::Live is included for the streaming proxy. The
# index/show actions don't touch `response.stream`, so they keep the
# normal request lifecycle — only `stream` flips into live mode.
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

  # stream — proxy the PAT plane's follow=true log endpoint straight
  # into the browser response. Chunks pass through untouched; the
  # client (log-stream Stimulus controller) does the line buffering
  # and per-line render.
  def stream
    if voodu_client.nil?
      response.headers["Content-Type"] = "text/plain"
      response.status = 503
      response.stream.write("no island selected\n")
      response.stream.close
      return
    end

    response.headers["Content-Type"]      = "text/plain; charset=utf-8"
    response.headers["Cache-Control"]     = "no-cache"
    response.headers["X-Accel-Buffering"] = "no" # nginx hint: don't buffer the chunks

    name   = params[:name]
    tail   = (params[:tail].presence || "20").to_i
    follow = params[:follow] != "false"

    voodu_client.logs_stream(name, follow: follow, tail: tail) do |chunk|
      response.stream.write(chunk)
    end
  rescue Voodu::Client::Error => e
    # Surface the error inline as a final stream line — the client
    # renders it as an ERROR-level row so the operator sees what
    # happened without leaving the page.
    safe_write("\n[stream error] #{e.message}\n")
  rescue ActionController::Live::ClientDisconnected
    # Browser closed the tab / navigated away. Normal teardown.
  ensure
    response.stream.close
  end

  private

  # safe_write — guards against writing after the stream is closed
  # (happens when the upstream errors AFTER the client disconnected).
  def safe_write(text)
    response.stream.write(text)
  rescue IOError, ActionController::Live::ClientDisconnected
    # Stream already torn down; nothing to do.
  end
end
