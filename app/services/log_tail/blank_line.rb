# frozen_string_literal: true

module LogTail
  # BlankLine — detects "orphan" warehouse rows that carry no log content: a
  # lone docker `--timestamps` prefix on a BLANK source line (FreeSWITCH prints
  # blank lines between SIP headers/body and around its trace separators). They
  # land with an empty message and a raw of just a timestamp, so the analytics
  # table falls back to showing the bare timestamp — visual litter, no info
  # (~10% of a chatty SIP pod's rows).
  #
  # LogTail::Reader drops these on read so they never reach the table / export.
  module BlankLine
    module_function

    # A leading RFC3339 / RFC3339Nano timestamp (the docker --timestamps prefix,
    # or an app's own per-line stamp). Anchored + DATE-qualified on purpose so a
    # FreeSWITCH "… at 16:36:12.891573:" line (bare wall-clock, no date) is never
    # mistaken for a timestamp-only row.
    LEADING_TS = /\A\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?\s*/

    # blank? — true when the row has no content beyond a timestamp. Mirrors the
    # Row's display (`msg` when present, else `raw`): strip a leading timestamp
    # from the effective content; an empty remainder ⇒ orphan.
    def blank?(msg, raw)
      content = msg.to_s.strip.empty? ? raw.to_s : msg.to_s

      content.sub(LEADING_TS, "").strip.empty?
    end
  end
end
