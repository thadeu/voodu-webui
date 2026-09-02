# frozen_string_literal: true

# Components::Activity::Row — one action, as a row of columns.
#
# Columns on `vmd:` and up, a stacked card below it. Not a real `<table>`: nine
# columns cannot survive 360px, and transposing per breakpoint means keeping
# the markup twice. One structure that reads as a table on a laptop and as a
# card on a phone is the same markup with a `flex-col vmd:flex-row` on it.
#
# Details — every resource the action touched, the files it came from, where
# the operator was — live in a `<details>` under the row. An action that
# touched five things has five things worth naming; putting them in the row
# makes every row unreadable to serve the one you are looking at.
#
# Renders ONLY what the controller recorded. A config row shows its key and the
# digest and never a value: the controller does not send one, and the screen
# must not become the hole the file format closed.
class Components::Activity::Row < Components::Base
  # The colour of the action itself, so an eye scanning the column can tell a
  # deploy from a deletion without reading. Deliberately NOT the status colour:
  # a successful delete is still a delete, and the two facts are separate.
  ACTION_TONES = {
    "apply" => "var(--voodu-blue)",
    "restart" => "var(--voodu-amber)",
    "delete" => "var(--voodu-red)",
    "rollback" => "var(--voodu-purple)",
    "config.set" => "var(--voodu-teal)",
    "config.delete" => "var(--voodu-red)"
  }.freeze

  # Origins as the operator says them, not as the wire spells them.
  ORIGIN_LABELS = {
    "cli" => "CLI",
    "ssh" => "SSH",
    "receive_pack" => "git push",
    "api" => "API",
    "deploy_plane" => "console"
  }.freeze

  def initialize(row:)
    @row = row
  end

  def view_template
    if expandable?
      details(
        class: "group border-b border-voodu-border-2 last:border-b-0",
        data: {activity_rows_target: "row", row_id: row_key}
      ) do
        summary(class: "list-none [&::-webkit-details-marker]:hidden cursor-pointer hover:bg-voodu-surface-2") { columns(expandable: true) }
        detail_panel
      end
    else
      div(class: "border-b border-voodu-border-2 last:border-b-0") { columns(expandable: false) }
    end
  end

  private

  # row_key identifies this row across a frame reload, so an expanded row comes
  # back expanded.
  #
  # The config key is still part of it, even though a config command is now one
  # row: rows written before that change are keyed by (id, key) in the
  # warehouse and are still in the 30-day window, and two of them sharing an id
  # would otherwise open and close together.
  def row_key
    [@row.activity_id, @row.config_key].compact_blank.join(":")
  end

  # Only the rows that have something more to say are clickable. A restart of
  # one pod has nothing behind it, and a disclosure arrow that opens an empty
  # panel teaches people to stop clicking the ones that are not empty.
  # Derived from what the panel would actually draw, not from a hand-kept list
  # of conditions. The list version drifted the moment the detail table learned
  # to build a row from a single-target action: a restart had a table to show
  # and no arrow to open it with.
  #
  # Note what is NOT here: the `-f` file list. It is still recorded and still
  # reaches the warehouse, it simply stopped earning a column, and a row whose
  # only extra fact is a filename has nothing worth opening for.
  def expandable?
    @row.client.present? || @row.error_message.present? || table_spec.present?
  end

  def columns(expandable:)
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-1 vmd:gap-3 px-3.5 py-2.5") do
      time_cell(expandable)
      action_cell
      scope_cell
      app_cell
      target_cell
      origin_cell
      client_cell
      duration_cell
      status_cell
    end
  end

  # When the operator FIRED the command, not when it landed.
  #
  # The stored timestamp is the closing one — the `finished` line overwrites
  # the `started` one so a row holds one action. But "when did this happen"
  # means when it began: an operator matching a CPU spike to a deploy is
  # looking for the moment the deploy started, and a 40-second rollout would
  # send them to the wrong end of it.
  #
  # Seconds, not just minutes, because most actions here take less than one and
  # HH:MM would make three of them look simultaneous. The end is in the title —
  # derivable from Took, but not worth making anyone do arithmetic for.
  def time_cell(expandable)
    div(class: "flex items-center gap-1.5 shrink-0 vmd:w-[74px]") do
      span(
        class: "text-voodu-muted-2 text-[9px] leading-none w-2 " \
               "#{expandable ? "group-open:rotate-90 transition-transform" : "invisible"}"
      ) { "▶" }

      span(
        class: "font-voodu-mono text-[11.5px] text-voodu-muted-2",
        title: time_title
      ) { WebTime.strftime(@row.started_at, "%H:%M:%S") }
    end
  end

  def time_title
    started = WebTime.strftime(@row.started_at, "%H:%M:%S")
    finished = WebTime.strftime(@row.ts, "%H:%M:%S")

    return "started #{started}" if started == finished

    "started #{started} · finished #{finished}"
  end

  def action_cell
    div(class: "shrink-0 vmd:w-[92px] pl-[14px] vmd:pl-0") do
      span(class: "text-[12.5px] font-medium", style: "color: #{action_tone};") { @row.action }
    end
  end

  # Scope is a link because narrowing to it is the first thing anyone does
  # after spotting a row. An action with no scope draws a dash rather than
  # nothing: an empty cell in a column reads as a rendering bug.
  def scope_cell
    div(class: "shrink-0 vmd:w-[100px] pl-[14px] vmd:pl-0 min-w-0") do
      if @row.scope.present?
        a(
          href: scope_href,
          class: "text-[11.5px] font-voodu-mono text-voodu-text-2 hover:text-voodu-link truncate block",
          title: "Filter to scope #{@row.scope}"
        ) { @row.scope }
      else
        dash
      end
    end
  end

  # WHICH application — the resource for a workload action, the bucket for a
  # config one. Split from Target because together they answered neither: a
  # `config.set` reported its key and never said which app the key belonged to,
  # and that is the first thing you need in order to care.
  def app_cell
    div(class: "shrink-0 vmd:w-[128px] pl-[14px] vmd:pl-0 min-w-0") do
      if @row.app.present?
        span(class: "text-[12px] font-voodu-mono text-voodu-text truncate block") { @row.app }
      else
        dash
      end
    end
  end

  # WHAT was done to it: the config key, or the count for a batch. Empty for a
  # single-resource action, where App already said everything.
  def target_cell
    div(class: "flex-1 min-w-0 pl-[14px] vmd:pl-0") do
      if @row.target.present?
        span(class: "text-[12px] font-voodu-mono text-voodu-text-2 truncate block") { @row.target }
      else
        dash
      end
    end
  end

  # Origin and actor share a cell: "who" is one question, and the answer is the
  # channel plus whoever it was authenticated as.
  def origin_cell
    div(class: "shrink-0 vmd:w-[110px] pl-[14px] vmd:pl-0 min-w-0") do
      span(class: "flex items-baseline gap-1 min-w-0") do
        # A short, fixed vocabulary — it always fits, so it never gives up
        # space to a PAT id that might be arbitrarily long.
        span(class: "text-[11px] text-voodu-muted shrink-0") { origin_label }

        if @row.actor.present?
          span(
            class: "text-[11px] font-voodu-mono text-voodu-muted-2 truncate min-w-0",
            title: @row.actor
          ) { "· #{@row.actor}" }
        end
      end
    end
  end

  # The summary half of the client block below. The row carries the two facts
  # that identify — address and city — and the panel keeps the network and the
  # word "declared".
  #
  # The title is where "declared" lives up here, because the column has no room
  # for the caveat and dropping it entirely would present a claim as a check.
  def client_cell
    div(class: "shrink-0 vmd:w-[168px] pl-[14px] vmd:pl-0 min-w-0") do
      ip = @row.client_ip

      if ip.blank?
        dash
      else
        # BOTH halves truncate, and both need `min-w-0` to do it: a flex item's
        # min-width resolves to its content by default, so `truncate` alone is
        # inert — the box simply grows and pushes the row.
        #
        # The address is not pinned with `shrink-0` either. An IPv4 always fits
        # and never truncates in practice, but an IPv6 is 39 characters and
        # would overflow the column outright. Nothing is lost when either one
        # is clipped: the title carries both in full.
        span(
          class: "flex items-baseline gap-1.5 min-w-0 cursor-help",
          title: client_title
        ) do
          span(class: "text-[11px] font-voodu-mono text-voodu-text-2 truncate min-w-0") { ip }

          if @row.client_location
            span(class: "text-[11px] text-voodu-muted truncate min-w-0") { @row.client_location }
          end
        end
      end
    end
  end

  # Everything the cell may clip, in full — the address included, now that it
  # can be truncated too.
  def client_title
    [
      [@row.client_ip, @row.client_location, @row.client_org].compact_blank.join(" · "),
      "Declared by the client machine, not verified by the controller"
    ].compact_blank.join("\n")
  end

  def duration_cell
    div(class: "shrink-0 vmd:w-[54px] vmd:text-right pl-[14px] vmd:pl-0") do
      seconds = @row.duration

      if seconds.nil?
        dash
      else
        span(class: "text-[11px] font-voodu-mono text-voodu-muted") { format_duration(seconds) }
      end
    end
  end

  def status_cell
    div(class: "shrink-0 vmd:w-[92px] pl-[14px] vmd:pl-0") do
      status = @row.effective_status

      render Components::UI::StatusPill.new(status: pill_state(status), label: status.capitalize)
    end
  end

  # ── The expanded panel ──────────────────────────────────────────

  # Error, then who, then what — the order somebody reads a row they opened
  # because something went wrong.
  def detail_panel
    # px-3.5 and no extra left inset: the panel lines up with the disclosure
    # arrow above it, so the eye follows one edge from the row into its detail
    # instead of stepping right at the boundary.
    div(class: "px-3.5 pb-3 pt-2 flex flex-col gap-3 bg-voodu-bg-2") do
      error_block if @row.error_message.present?
      client_line if @row.client.present?
      detail_table
    end
  end

  # detail_table — one table per ACTION, with the columns that action actually
  # has. See Components::Activity::DetailTable for why this is not one shape
  # with blanks in it.
  def detail_table
    spec = table_spec
    return if spec.nil?

    render Components::Activity::DetailTable.new(**spec)

    digest_note if @row.config_action?
  end

  def table_spec
    return @table_spec if defined?(@table_spec)

    @table_spec = @row.config_action? ? config_table : resource_table
  end

  # Resources of an apply, and of anything else that names manifests. Falls
  # back to the row's own (kind, scope, name) so a restart or a delete — which
  # touch exactly one thing and carry no resource list — still get a table
  # instead of an empty panel.
  #
  # A rollback grows a Release column: the new release id is the row that joins
  # this action to the release history, and it is the only place it appears.
  def resource_table
    rows = @row.resources.map { |r| [r["kind"], r["scope"], r["name"]] }

    if rows.empty? && @row.kind.present?
      rows = [[@row.kind, @row.scope, @row.name]]
    end

    return nil if rows.empty?

    if @row.release_id.present?
      return {
        caption: "Resources",
        headers: ["kind", "scope", "name", "release"],
        rows: rows.map { |r| r + [@row.release_id] }
      }
    end

    {caption: "Resources", headers: ["kind", "scope", "name"], rows: rows}
  end

  # A config change is a set of keys in a bucket, so its columns are the key
  # and the digest — one ROW PER KEY, because `vd config set A=1 B=2 C=3` is
  # one command that touched three things.
  #
  # The app is not a column here: it is the same for every key in the command
  # and already sits in the App column of the row above. Repeating it three
  # times would be three cells of the same word.
  #
  # The VALUE is not a column and never will be — the controller does not send
  # one.
  def config_table
    changes = @row.config_changes
    return nil if changes.empty?

    {
      caption: "Config",
      headers: ["key", "digest"],
      rows: changes.map { |change| [change["key"], change["value_digest"]] }
    }
  end

  def error_block
    div(class: "text-[11.5px] font-voodu-mono break-words", style: "color: var(--voodu-red);") do
      @row.error_message
    end
  end

  # Labelled "declared", and that word is doing work. The controller cannot see
  # this: its view of a CLI peer is always 127.0.0.1, because the CLI talks to
  # the loopback port and remote work runs on the box. The address is what the
  # operator's own machine reported, so the screen says so rather than
  # presenting it as something we checked.
  def client_line
    detail_section("Client (declared)") do
      div(class: "flex flex-wrap items-baseline gap-x-3 gap-y-0.5 text-[11px] min-w-0") do
        if @row.client_ip.present?
          span(class: "font-voodu-mono text-voodu-text-2") { @row.client_ip }
        end

        span(class: "text-voodu-muted") { @row.client_location } if @row.client_location
        span(class: "text-voodu-muted-2") { @row.client_org } if @row.client_org
      end
    end
  end

  # Kept beside the config table rather than dropped with the old block: it is
  # the line that states what the trail deliberately does NOT hold, and the
  # digest column is meaningless without it.
  def digest_note
    span(class: "text-[10.5px] text-voodu-muted-2") { "the value itself is never recorded" }
  end

  def detail_section(label, &)
    div(class: "flex flex-col gap-1") do
      span(class: "text-[10px] font-semibold uppercase tracking-[0.08em] text-voodu-muted") { label }
      yield
    end
  end

  # ── Bits ────────────────────────────────────────────────────────

  def dash
    span(class: "text-[11px] text-voodu-muted-2") { "—" }
  end

  # Sub-second actions are the common case (a config write is a store round
  # trip), and "112ms" beside "2m 04s" reads better than "0.1s".
  def format_duration(seconds)
    return "#{(seconds * 1000).round}ms" if seconds < 1
    return "#{seconds.round(1)}s" if seconds < 60

    minutes, rest = seconds.divmod(60)
    "#{minutes.to_i}m #{rest.round.to_s.rjust(2, "0")}s"
  end

  # `running` borrows the restarting pill, which draws a spinner instead of a
  # dot — the one state on this screen that is still moving, and the reason the
  # frame reloads at all.
  def pill_state(status)
    case status
    when ActivityAction::IN_FLIGHT then :restarting
    when "succeeded" then :succeeded
    when "failed" then :failed
    when "partial" then :partial
    else :unknown
    end
  end

  def action_tone
    ACTION_TONES.fetch(@row.action, "var(--voodu-text-2)")
  end

  def origin_label
    ORIGIN_LABELS.fetch(@row.origin, @row.origin.presence || "unknown")
  end

  # Keeps every other filter, so clicking a scope narrows the view instead of
  # resetting it. Drops `page` — the first page of a narrower list is the one
  # the operator wants, not page 4 of it.
  def scope_href
    activity_path(
      request.query_parameters.merge(scope: @row.scope).except("page", "before", "after")
    )
  end
end
