# frozen_string_literal: true

require "csv"

# LogTail::LineFormatter — turns a parsed warehouse line (the
# { ts:, pod:, stream:, level:, msg:, raw:, parsed: } hash) into one
# serialised output line for a given format. The single serialiser
# behind the /logs/analytics export (LogsAnalyticsController#export).
#
# Line-oriented formats only (ndjson / txt / csv) — each #line returns a
# string WITH its trailing newline. JSON-array output is built by the
# caller (it isn't line-oriented), reusing #row_hash for the shape.
module LogTail
  module LineFormatter
    module_function

    LINE_FORMATS = %w[ndjson txt csv].freeze

    CSV_COLUMNS = %w[ts pod stream level msg].freeze

    # header — the once-per-file header line for a format, or nil when the
    # format is header-less (ndjson / txt). CSV gets its column row.
    def header(format)
      return unless format == "csv"

      CSV.generate_line(CSV_COLUMNS)
    end

    # line — one formatted row (with trailing newline).
    def line(hash, format)
      case format
      when "csv" then csv_line(hash)
      when "txt" then txt_line(hash)
      else            ndjson_line(hash)
      end
    end

    # ndjson_line — the FULL parsed record (ts/pod/stream/level/msg/raw/
    # parsed), one JSON object per line. Matches what the warehouse stores,
    # so raw context survives export.
    def ndjson_line(hash)
      "#{JSON.generate(hash)}\n"
    end

    # txt_line — "TS [pod] LEVEL msg" + newline. LEVEL omitted when the
    # source line wasn't structured. Mirrors the on-screen log render.
    def txt_line(hash)
      r = row_hash(hash)
      pieces = [r[:ts], "[#{r[:pod]}]"]
      pieces << r[:level] if r[:level].present?
      pieces << r[:msg].to_s
      "#{pieces.join(' ')}\n"
    end

    # csv_line — RFC 4180 via CSV.generate_line (quotes commas/quotes/
    # newlines). Columns match CSV_COLUMNS / the header.
    def csv_line(hash)
      r = row_hash(hash)
      CSV.generate_line([r[:ts], r[:pod], r[:stream], r[:level], r[:msg]])
    end

    # row_hash — normalise string/symbol keys into a symbol-keyed hash so
    # the formatters read uniformly regardless of source (Reader yields
    # string keys; in-memory shapers use symbols).
    def row_hash(hash)
      {
        ts:     hash[:ts]     || hash["ts"],
        pod:    hash[:pod]    || hash["pod"],
        stream: hash[:stream] || hash["stream"],
        level:  hash[:level]  || hash["level"],
        msg:    hash[:msg]    || hash["msg"]
      }
    end
  end
end
