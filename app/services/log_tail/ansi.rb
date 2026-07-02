# frozen_string_literal: true

module LogTail
  # Ansi — the single Ruby definition of "strip terminal colour escapes".
  # A TTY app (FreeSWITCH's SIP trace, a colourised logger) prints SGR/CSI
  # escapes to stdout; the invisible ESC renders to nothing in a browser and
  # leaves `[m`/`[32m` litter inline. We scrub on BOTH sides of the warehouse:
  # on WRITE (LogTail::Parser) so newly-stored lines are clean, and on READ
  # (LogTail::Reader) so lines captured BEFORE that fix — or by any path that
  # skipped it — still come back clean. The live-tail client strips the same in
  # JS for the direct docker proxy that never touches the warehouse.
  module Ansi
    module_function

    # CSI escape: ESC `[`, optional params, optional intermediates, a final
    # byte. Covers the SGR colour codes (`\e[m`, `\e[32m`, `\e[1;36m`) plus the
    # cursor/erase sequences a console app might emit.
    PATTERN = /\e\[[0-9;?]*[ -\/]*[@-~]/

    # strip — drop every ANSI escape from `str`. nil-safe; a clean line is a
    # cheap no-op miss (returned unchanged).
    def strip(str)
      str.to_s.gsub(PATTERN, "")
    end
  end
end
