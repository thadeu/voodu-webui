# frozen_string_literal: true

# LogExportJob — materialises one LogExport request to disk.
#
# Reads NDJSON warehouse files via LogTail::Reader, applies the
# operator's filters (period, pods, content search), writes the
# result to storage/exports/<id>.{ndjson|zip}, and broadcasts a
# Turbo Stream update so the drawer body morphs from "Generating…"
# to "Ready · Download".
#
# Timeout: 30s (operator decision). Anything longer than that
# means the period is too wide / pods too many — drawer surfaces
# a "Try a narrower range" message + Retry button.
#
# Output formats:
#   - Single .ndjson file (default) — every matching line concatenated
#   - .zip with one .ndjson per pod (when group_by_pod = true)
#
# Atomicity: writes to a `.partial` temp file first, then renames
# atomically. The cleanup job will reap orphan .partials safely
# (it only deletes files referenced by a row).
class LogExportJob < ApplicationJob
  queue_as :default

  # Job-level timeout. We set it explicitly because the default
  # Solid Queue retry-on-failure would mask "too wide" exports
  # by retrying them forever.
  TIMEOUT_SECONDS = 30

  # How long the generated file stays on disk after `ready_at`
  # before the cleanup job reaps it.
  ARTIFACT_TTL = 24.hours

  discard_on Voodu::Client::AuthError

  def perform(export_id)
    export = LogExport.find_by(id: export_id)
    return unless export

    export.update!(status: "running")
    broadcast(export)

    started_at = Time.current

    Timeout.timeout(TIMEOUT_SECONDS) do
      generate!(export)
    end

    elapsed = (Time.current - started_at).round(2)
    Rails.logger.info(
      "log-export #{export.id} ready bytes=#{export.file_size_bytes} " \
      "lines=#{export.line_count} elapsed=#{elapsed}s"
    )
  rescue Timeout::Error
    fail_export!(export, "Timeout after #{TIMEOUT_SECONDS}s — try a narrower range or fewer pods")
  rescue StandardError => e
    fail_export!(export, "#{e.class}: #{e.message}")
    raise
  end

  private

  def generate!(export)
    if export.group_by_pod?
      generate_zip!(export)
    else
      generate_single!(export)
    end

    export.update!(
      status:     "ready",
      ready_at:   Time.current,
      expires_at: Time.current + ARTIFACT_TTL
    )
    broadcast(export)
  end

  # generate_single! — concat all matching lines into one file in the
  # operator-chosen format (ndjson/txt/csv).
  def generate_single!(export)
    ext       = export.format            # "ndjson" | "txt" | "csv"
    rel_path  = relative_path(export, ext)
    abs_path  = Rails.root.join(rel_path)
    tmp_path  = "#{abs_path}.partial"

    LogTail::FilePath.ensure_dir(File.dirname(abs_path))

    line_count = 0
    File.open(tmp_path, "w") do |out|
      write_header(out, export.format)

      LogTail::Reader.each_line(
        island_id:      export.island_id,
        pods:           filter_pods(export),
        from:           export.from_time || 2.days.ago,
        until_:         export.until_time || Time.current,
        content_search: export.content_search,
        regex:          export.content_regex?
      ) do |_pod, hash|
        out.write(format_line(hash, export.format))
        line_count += 1
      end
    end

    File.rename(tmp_path, abs_path)

    export.update!(
      file_path:       rel_path,
      file_size_bytes: File.size(abs_path),
      line_count:      line_count
    )
  end

  # generate_zip! — one file per pod inside a single .zip archive,
  # each file in the operator-chosen format. Useful for "All pods"
  # exports where the operator wants to grep per pod after the fact.
  def generate_zip!(export)
    require "zip"

    inner_ext = export.format            # "ndjson" | "txt" | "csv"
    ext       = "zip"
    rel_path  = relative_path(export, ext)
    abs_path  = Rails.root.join(rel_path)
    tmp_path  = "#{abs_path}.partial"

    LogTail::FilePath.ensure_dir(File.dirname(abs_path))

    # Group lines by pod in memory first. For a 30s-bounded job
    # this is fine; pathological cases will hit the timeout
    # before exhausting RAM (50k line cap × ~500 bytes = ~25MB).
    by_pod     = Hash.new { |h, k| h[k] = [] }
    line_count = 0

    LogTail::Reader.each_line(
      island_id:      export.island_id,
      pods:           filter_pods(export),
      from:           export.from_time || 2.days.ago,
      until_:         export.until_time || Time.current,
      content_search: export.content_search,
      regex:          export.content_regex?
    ) do |pod, hash|
      by_pod[pod] << hash
      line_count += 1
    end

    Zip::File.open(tmp_path, Zip::File::CREATE) do |zip|
      by_pod.each do |pod, lines|
        entry_name = "#{LogTail::FilePath.safe_pod_name(pod)}.#{inner_ext}"
        zip.get_output_stream(entry_name) do |out|
          write_header(out, export.format)
          lines.each { |hash| out.write(format_line(hash, export.format)) }
        end
      end
    end

    File.rename(tmp_path, abs_path)

    export.update!(
      file_path:       rel_path,
      file_size_bytes: File.size(abs_path),
      line_count:      line_count
    )
  end

  # ── Format-specific encoders ─────────────────────────────────────
  #
  # Each format gets two hooks: write_header (called once per file
  # before any rows — CSV uses it for the column header; ndjson/txt
  # are header-less) and format_line (called per row).
  #
  # All formats include the trailing newline so callers don't have
  # to remember to add one.

  def write_header(io, format)
    return unless format == "csv"

    require "csv"
    io.write(CSV.generate_line(%w[ts pod stream level msg]))
  end

  def format_line(hash, format)
    case format
    when "csv"   then format_csv_line(hash)
    when "txt"   then format_txt_line(hash)
    else              format_ndjson_line(hash)  # default + explicit "ndjson"
    end
  end

  def format_ndjson_line(hash)
    "#{JSON.generate(hash)}\n"
  end

  # format_txt_line — "TS [pod] LEVEL msg" + newline. LEVEL omitted
  # when not parsed (plain-text source line). Mirrors the on-screen
  # /logs render so the export reads the same way as what the
  # operator was watching live.
  def format_txt_line(hash)
    ts    = hash[:ts]    || hash["ts"]
    pod   = hash[:pod]   || hash["pod"]
    level = hash[:level] || hash["level"]
    msg   = hash[:msg]   || hash["msg"]

    pieces = [ts, "[#{pod}]"]
    pieces << level if level.present?
    pieces << msg.to_s
    "#{pieces.join(' ')}\n"
  end

  # format_csv_line — RFC 4180 compliant via CSV.generate_line.
  # Quotes anything containing commas, quotes, or newlines. Header
  # is written once per file by write_header.
  def format_csv_line(hash)
    require "csv"
    CSV.generate_line([
      hash[:ts]     || hash["ts"],
      hash[:pod]    || hash["pod"],
      hash[:stream] || hash["stream"],
      hash[:level]  || hash["level"],
      hash[:msg]    || hash["msg"]
    ])
  end

  def relative_path(export, ext)
    "storage/exports/#{export.id}.#{ext}"
  end

  # filter_pods — returns the array LogTail::Reader expects.
  # nil/empty = "all pods on disk for this island"; explicit list
  # selects only those pods.
  def filter_pods(export)
    return nil if export.all_pods?

    export.pods
  end

  def fail_export!(export, message)
    return if export.nil?

    export.update!(status: "failed", error: message)
    broadcast(export)
    Rails.logger.warn("log-export #{export.id} failed: #{message}")
  end

  # broadcast — Turbo Stream update of the drawer body so the
  # operator sees the state transition (queued → running → ready/
  # failed) without polling. The target is "log-export-<id>" — the
  # drawer body wraps its content in that id.
  def broadcast(export)
    # Ship ONLY the state-block markup — not the full ExportStatus
    # component. Broadcasting `ExportStatus.new(...).call` would
    # replace the inner div with another full wrapper (header row,
    # cable source, params summary, AND another nested
    # `#log-export-<id>` div), duplicating the back-to-filter chip
    # and the cable subscription on every state transition. The
    # class-method seam keeps the broadcast surgical.
    Turbo::StreamsChannel.broadcast_update_to(
      "log-export-#{export.id}",
      target: "log-export-#{export.id}",
      html:   Components::Logs::ExportStatus.state_block_for(export)
    )
  rescue StandardError => e
    Rails.logger.warn("log-export broadcast #{export.id} failed: #{e.class}: #{e.message}")
  end
end
