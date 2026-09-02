# frozen_string_literal: true

require "test_helper"

# Exercises the full request stack, which also smoke-renders the Phlex
# Index/Frame views and every activity component — a render error surfaces as a
# 500 here rather than the first time an operator opens the page.
class ActivityControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    ActivityAction.delete_all
    @server = servers(:alpha)
    @key = @server.key

    # Frozen to midday so the "Today" / "Yesterday" day labels and the
    # in-flight age threshold never straddle midnight mid-run.
    travel_to Time.utc(2026, 6, 16, 12, 0, 0)
  end

  teardown do
    travel_back
    ActivityAction.delete_all
  end

  # record writes straight to the warehouse — the ingest has its own tests, and
  # going through it here would test the poller contract twice.
  def record(id:, action: "apply", event: "done", at: Time.current, **payload)
    line = {
      "id" => id, "ts" => at.utc.iso8601, "event" => event, "action" => action
    }.merge(payload.transform_keys(&:to_s))

    ActivityAction.create!(
      server_id: @server.id,
      activity_id: id,
      config_key: payload[:config_key].to_s,
      event: event,
      event_rank: ActivityAction::EVENT_RANK.fetch(event),
      action: action,
      ts_iso: line["ts"],
      payload: line.to_json
    )
  end

  test "index renders an action with its outcome" do
    record(id: "a1", action: "apply", origin: "cli", scope: "runa", name: "checkoutsvc",
      status: "succeeded", elapsed_ms: 1200)

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "Activity"
    assert_includes response.body, "apply"
    assert_includes response.body, "checkoutsvc"
    assert_includes response.body, "Succeeded"
  end

  test "the empty state distinguishes an untouched server from a narrow filter" do
    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "Nothing recorded on this server yet"

    record(id: "a1", action: "apply", status: "succeeded")

    get activity_path(server_key: @key, act: "rollback")

    assert_response :success
    assert_includes response.body, "No actions match these filters"
  end

  test "filters narrow the list and compose" do
    record(id: "a1", action: "apply", origin: "cli", status: "succeeded", name: "checkoutsvc")
    record(id: "a2", action: "delete", origin: "ssh", status: "succeeded", name: "billingjob")

    get activity_path(server_key: @key, act: "delete")

    assert_response :success
    assert_includes response.body, "billingjob"
    # Names chosen so they cannot appear in the page chrome — "web" is a
    # substring of apple-mobile-web-app-capable in the <head>, which would
    # make this refute fail for a reason that has nothing to do with filtering.
    refute_includes response.body, "checkoutsvc"

    # A filter that matches the action but not the origin returns nothing —
    # the two narrow together rather than either winning.
    get activity_path(server_key: @key, act: "delete", origin: "cli")

    assert_response :success
    assert_includes response.body, "No actions match these filters"
  end

  # `act`, not `action`: Rails writes the controller action into params[:action]
  # from the route, so a filter by that name would silently never apply. This
  # is the test that catches somebody "fixing" the param name back.
  test "the action filter is not clobbered by the route's own action param" do
    record(id: "a1", action: "apply", status: "succeeded", name: "checkoutsvc")

    get activity_path(server_key: @key, act: "apply")

    assert_response :success
    assert_includes response.body, "checkoutsvc"
  end

  test "a running action shows as running and ages into unknown" do
    record(id: "a1", action: "apply", event: "started", origin: "cli", name: "checkoutsvc",
      at: 2.minutes.ago)

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "Running"

    ActivityAction.delete_all
    record(id: "a2", action: "apply", event: "started", origin: "cli", name: "checkoutsvc",
      at: 3.hours.ago)

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "Unknown"
  end

  # The screen must not become the hole the file format closed. The controller
  # never sends a value; nothing on this page may invent one.
  #
  # Written in the OLDER per-key shape on purpose: those rows are still in the
  # 30-day window, and the reader has to keep answering for them until they age
  # out on their own.
  test "a legacy per-key config row still shows its key and digest" do
    record(id: "c1", action: "config.set", origin: "cli", scope: "acme",
      config_key: "DATABASE_URL", value_digest: "aa11bb", status: "succeeded")

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "DATABASE_URL"
    assert_includes response.body, "aa11bb"
    assert_includes response.body, "config.set"
  end

  test "a batch apply names the count instead of inventing one name" do
    record(id: "a1", action: "apply", origin: "cli", scope: "runa", status: "succeeded",
      resources: [
        {"kind" => "statefulset", "scope" => "runa", "name" => "pg"},
        {"kind" => "statefulset", "scope" => "runa", "name" => "redis"}
      ])

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "2 resources"
  end

  # The exact shape already in a live warehouse: rows recorded before the
  # controller learned to set a batch-wide scope carry neither scope nor name,
  # only the resource list. The page must render them rather than blow up on
  # the two nils.
  test "a row with no scope and no name still renders" do
    record(id: "a1", action: "apply", origin: "cli", status: "succeeded", elapsed_ms: 112,
      resources: [
        {"kind" => "asset", "scope" => "runa", "name" => "pg"},
        {"kind" => "statefulset", "scope" => "runa", "name" => "pg"},
        {"kind" => "statefulset", "scope" => "runa", "name" => "rabbitmq"},
        {"kind" => "asset", "scope" => "runa", "name" => "redis"},
        {"kind" => "statefulset", "scope" => "runa", "name" => "redis"}
      ])

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "5 resources"
    assert_includes response.body, "112ms"
    assert_includes response.body, "CLI"
  end

  # The client attribution the CLI declares. The controller cannot observe it:
  # its view of a CLI peer is always 127.0.0.1, because the CLI talks to the
  # loopback port and remote work runs on the box.
  test "an action shows who ran it" do
    record(id: "a1", action: "apply", origin: "ssh", scope: "runa", name: "checkoutsvc",
      status: "succeeded", elapsed_ms: 2400,
      client: {"ip" => "189.4.22.10", "city" => "Sao Paulo", "country" => "BR",
               "org" => "AS28573 Claro S.A."})

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "189.4.22.10"
    assert_includes response.body, "Sao Paulo, BR"
    assert_includes response.body, "AS28573 Claro S.A."
    # The word is load-bearing: this address is what the operator's own machine
    # reported, not something the controller checked.
    assert_includes response.body, "declared"
  end

  # The `-f` arguments stopped earning a column — most rows had none, and a
  # mostly-dashed column takes width without paying for it. They are STILL
  # recorded, so the decision is reversible without touching the controller or
  # redeploying anything.
  test "the file list is still recorded even though the table stopped showing it" do
    record(id: "a1", action: "apply", status: "succeeded", files: ["infra/db.hcl", "infra/web.hcl"])

    assert_equal ["infra/db.hcl", "infra/web.hcl"], ActivityAction.first.files

    get activity_path(server_key: @key)

    assert_response :success
    refute_includes response.body, "infra/db.hcl",
      "the file column is back — it was removed on purpose; see Components::Activity::Row"
  end

  # "apply of what, exactly" — the question a wrapping row of identical-looking
  # chips could not answer. In columns the kinds stack and an `asset` is
  # visibly not a `statefulset`.
  test "an apply expands into a resource table with kind, scope and name" do
    record(id: "a1", action: "apply", origin: "cli", scope: "runa", status: "succeeded",
      resources: [
        {"kind" => "asset", "scope" => "runa", "name" => "pg"},
        {"kind" => "statefulset", "scope" => "runa", "name" => "rabbitmq"}
      ])

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "Resources"
    assert_includes response.body, "asset"
    assert_includes response.body, "statefulset"
    assert_includes response.body, "rabbitmq"
  end

  # Each action gets the columns it actually has. Forcing a config change
  # through the resource shape means a row of blanks where the shape does not
  # fit, and blanks are what made the panel unreadable.
  test "a config change expands into a key/digest table, never a value" do
    record(id: "c1", action: "config.set", origin: "cli", scope: "runa", name: "pg",
      config_keys: [{"key" => "PG_SHARED_USER", "value_digest" => "d80dc0a202c8"}],
      status: "succeeded")

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "Config"
    assert_includes response.body, "PG_SHARED_USER"
    assert_includes response.body, "d80dc0a202c8"
    assert_includes response.body, "the value itself is never recorded"
  end

  # `vd config set VAR=1 VAR1=2 VAR2=3` is ONE thing the operator did. It used
  # to land as three rows sharing an id, and the screen counted three changes
  # where one happened.
  test "a config command with several keys is one row expanding into a table" do
    record(id: "c1", action: "config.set", origin: "cli", scope: "runa", name: "pg",
      status: "succeeded",
      config_keys: [
        {"key" => "VAR", "value_digest" => "aa11"},
        {"key" => "VAR1", "value_digest" => "bb22"},
        {"key" => "VAR2", "value_digest" => "cc33"}
      ])

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "3 vars"

    %w[VAR VAR1 VAR2 aa11 bb22 cc33].each do |value|
      assert_includes response.body, value
    end

    # The app is NOT repeated per key: it is the same for the whole command and
    # already sits in the App column of the row above.
    assert_equal 1, response.body.scan(">pg<").count
  end

  # A config row used to report its KEY as the target and never say which app
  # owned it — the first thing you need in order to care about the change.
  test "a config change names the app the keys belong to" do
    record(id: "c1", action: "config.set", scope: "runa", name: "pg",
      config_keys: [{"key" => "PG_SHARED_USER", "value_digest" => "aa11"}],
      status: "succeeded")

    row = ActivityAction.first

    assert_equal "pg", row.app
    assert_equal "PG_SHARED_USER", row.target
  end

  # Rows written in the older per-key shape are still inside the 30-day window,
  # and two of them share an action id — keyed on the id alone they would open
  # and close together.
  test "legacy per-key config rows get distinct restore ids" do
    record(id: "c1", action: "config.set", config_key: "PG_USER", value_digest: "aa11", status: "succeeded")
    record(id: "c1", action: "config.set", config_key: "PG_PASS", value_digest: "bb22", status: "succeeded")

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, 'data-row-id="c1:PG_USER"'
    assert_includes response.body, 'data-row-id="c1:PG_PASS"'
  end

  # A restart or a delete carries no resource list — it touches exactly one
  # thing. The panel builds a table from the row itself rather than showing
  # nothing.
  test "a single-target action still gets a resource table" do
    record(id: "a1", action: "restart", scope: "runa", kind: "statefulset", name: "pg",
      status: "succeeded")

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "Resources"
    assert_includes response.body, "statefulset"
  end

  # The new release id is the row that joins this action to the release
  # history, and this table is the only place it appears.
  test "a rollback shows the release it produced" do
    record(id: "r1", action: "rollback", scope: "runa", kind: "deployment", name: "web",
      release_id: "rel-42", status: "succeeded")

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "release"
    assert_includes response.body, "rel-42"
  end

  # A batch has no single app; a single-resource action has no separate target.
  # Both say so with a dash rather than inventing a value.
  test "app and target divide the work instead of overlapping" do
    record(id: "a1", action: "apply", scope: "runa", status: "succeeded",
      resources: [
        {"kind" => "statefulset", "scope" => "runa", "name" => "pg"},
        {"kind" => "statefulset", "scope" => "runa", "name" => "redis"}
      ])
    record(id: "a2", action: "apply", scope: "runa", name: "web", status: "succeeded",
      resources: [{"kind" => "deployment", "scope" => "runa", "name" => "web"}])

    batch = ActivityAction.find_by(activity_id: "a1")
    single = ActivityAction.find_by(activity_id: "a2")

    assert_nil batch.app
    assert_equal "2 resources", batch.target

    assert_equal "web", single.app
    assert_nil single.target
  end

  # The stored timestamp is the CLOSING one — the finished line overwrites the
  # started line so a row holds one action. "When did this happen" means when
  # it began, though: matching a CPU spike to a deploy means finding the moment
  # the deploy started, and a 40-second rollout would send you to the wrong end
  # of it.
  test "the time column shows when the command started, not when it landed" do
    finished = Time.utc(2026, 6, 16, 11, 30, 40)

    record(id: "a1", action: "apply", scope: "runa", status: "succeeded",
      at: finished, elapsed_ms: 40_000,
      resources: [{"kind" => "deployment", "scope" => "runa", "name" => "web"}])

    row = ActivityAction.first

    assert_equal Time.utc(2026, 6, 16, 11, 30, 0), row.started_at
    assert_equal finished, row.ts

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "11:30:00"
    assert_includes response.body, "started 11:30:00 · finished 11:30:40"
  end

  # An action with no duration began when it was recorded, so the title says
  # one time rather than repeating the same moment twice.
  test "an instantaneous action reports a single moment" do
    at = Time.utc(2026, 6, 16, 11, 30, 0)

    record(id: "c1", action: "config.set", scope: "runa", name: "pg", at: at,
      config_keys: [{"key" => "FOO", "value_digest" => "aa11"}], status: "succeeded")

    row = ActivityAction.first

    assert_equal row.ts, row.started_at

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "started 11:30:00"
    refute_includes response.body, "finished 11:30:00"
  end

  # A flex item's min-width resolves to its content, so `truncate` alone is
  # inert — the box grows and pushes the row. An IPv6 is 39 characters against
  # a 168px column, which is where that stops being theoretical.
  test "a long address and a long city are clipped rather than pushing the row" do
    record(id: "a1", action: "apply", scope: "runa", status: "succeeded",
      client: {"ip" => "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
               "city" => "Ribeirao Preto do Norte", "country" => "BR",
               "org" => "AS53184 VERO INTERNET E TELECOMUNICACOES S.A"})

    get activity_path(server_key: @key)

    assert_response :success

    body = response.body

    # Both halves can shrink. Without min-w-0 the truncate class is decoration.
    assert_includes body, "truncate min-w-0"

    # Nothing is lost to the clipping: the title carries all three in full.
    assert_includes body, "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
    assert_includes body, "Ribeirao Preto do Norte, BR"
    assert_includes body, "AS53184 VERO INTERNET E TELECOMUNICACOES S.A"
  end

  # The actor is a PAT id of no fixed length, and it used to carry `truncate`
  # on an inline span, where overflow-hidden does nothing at all.
  test "a long actor is clipped and kept in full in the title" do
    record(id: "a1", action: "restart", origin: "api", scope: "runa", kind: "deployment",
      name: "web", status: "succeeded",
      actor: "pat_01HQ8XKJ9WVXYZ0123456789ABCDEFGHIJKLMNOP")

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, 'title="pat_01HQ8XKJ9WVXYZ0123456789ABCDEFGHIJKLMNOP"'
  end

  # The same picker Metrics and Alerts use, custom window included. A third
  # time picker with its own idea of what "7d" means is how two screens start
  # disagreeing about the same question.
  test "a custom range window is honoured" do
    # Both records sit inside the window a dropped from/until would fall back
    # to (the last day). Only the bounds actually arriving can separate them —
    # the earlier version of this test used a record from six days back, so it
    # passed whether or not the params were read at all.
    record(id: "outside", action: "apply", status: "succeeded", name: "checkoutsvc",
      at: Time.utc(2026, 6, 16, 9, 0, 0))
    record(id: "inside", action: "apply", status: "succeeded", name: "billingjob",
      at: Time.utc(2026, 6, 16, 11, 0, 0))

    get activity_path(server_key: @key, range: "custom",
      from: "2026-06-16T10:00", until: "2026-06-16T12:00")

    assert_response :success
    assert_includes response.body, "billingjob"
    refute_includes response.body, "checkoutsvc"
  end

  # The picker reopens showing what it was given, so an operator can see the
  # window they are looking at rather than the one it defaulted to.
  test "a custom range is echoed back into the picker" do
    get activity_path(server_key: @key, range: "custom",
      from: "2026-06-16T10:00", until: "2026-06-16T12:00")

    assert_response :success
    assert_includes response.body, "2026-06-16T10:00"
    assert_includes response.body, "2026-06-16T12:00"
  end

  # The range picker ships its own form and a form cannot nest, so the
  # dropdowns live in a second one. Each has to carry the other's state or
  # changing one silently clears the other.
  test "the two filter forms carry each other's state" do
    record(id: "a1", action: "apply", status: "failed", name: "checkoutsvc")

    get activity_path(server_key: @key, range: "24h", status: "failed", act: "apply")

    assert_response :success

    body = response.body

    # The range form carries the dropdown selections forward...
    assert_includes body, 'name="status" value="failed"'
    assert_includes body, 'name="act" value="apply"'

    # ...and the dropdown form carries the window.
    assert_includes body, 'name="range" value="24h"'
  end

  test "the filters are multi-select dropdowns, not a wall of chips" do
    get activity_path(server_key: @key)

    assert_response :success

    body = response.body

    assert_includes body, "ds-multiselect"
    assert_includes body, 'name="status[]"'
    assert_includes body, 'name="act[]"'
    # Server-rendered labels, so there is no flash of the wrong word before the
    # Stimulus controller connects.
    assert_includes body, "All statuses"
    assert_includes body, "All actions"
  end

  # A checkbox group submits repeated keys; a shared link and the range form
  # both use the comma form. Both have to work.
  test "a repeated-key selection filters the same as a comma-joined one" do
    record(id: "a1", action: "apply", status: "succeeded", name: "checkoutsvc")
    record(id: "a2", action: "delete", status: "succeeded", name: "billingjob")

    get activity_path(server_key: @key, act: ["apply", "delete"])

    assert_response :success
    assert_includes response.body, "checkoutsvc"
    assert_includes response.body, "billingjob"

    get activity_path(server_key: @key, act: "apply,delete")

    assert_response :success
    assert_includes response.body, "checkoutsvc"
    assert_includes response.body, "billingjob"
  end

  # Right after the last dropdown, where the controls it clears are, and icon
  # only — a third labelled control would push the strip past the table's own
  # left edge on a laptop.
  test "clear filters is an icon button beside the dropdowns, and only when there is something to clear" do
    get activity_path(server_key: @key)

    assert_response :success
    refute_includes response.body, 'aria-label="Clear filters"'

    get activity_path(server_key: @key, status: "failed")

    assert_response :success
    assert_includes response.body, 'aria-label="Clear filters"'
  end

  # A menu that submits on every tick reloads the frame under itself, so the
  # operator picks one option and the dropdown disappears. Committing on close
  # applies the whole set at once.
  test "the filter menus apply as a set when they close, not on every tick" do
    get activity_path(server_key: @key)

    assert_response :success

    body = response.body

    # Phlex does not escape `>` inside an attribute value, so this is the
    # literal rendered string.
    assert_includes body, "ds-multiselect:commit->auto-submit#submit"
    refute_includes body, "change->auto-submit#submit",
      "submitting on change reloads the frame mid-selection and closes the menu"
  end

  # "Any word" means the ones that are NOT columns: a resource name inside a
  # batch, a config key, an IP, the city. A column-list search would answer for
  # four of those and silently miss the rest.
  test "the search box matches anything recorded on the row" do
    record(id: "a1", action: "apply", scope: "runa", status: "succeeded",
      resources: [{"kind" => "statefulset", "scope" => "runa", "name" => "rabbitmq"}],
      client: {"ip" => "177.87.32.54", "city" => "Porto Alegre", "country" => "BR"})
    record(id: "a2", action: "apply", scope: "other", status: "succeeded", name: "checkoutsvc")

    # A resource name that only exists inside the batch, never in a column.
    get activity_path(server_key: @key, q: "rabbitmq")

    assert_response :success
    assert_includes response.body, "runa"
    refute_includes response.body, "checkoutsvc"

    # An address, which is not a column either.
    get activity_path(server_key: @key, q: "177.87.32.54")

    assert_response :success
    assert_includes response.body, "rabbitmq"
    refute_includes response.body, "checkoutsvc"
  end

  # Config keys are full of underscores. Unescaped, each one is a LIKE wildcard
  # matching any character, so PG_USER would also match PGXUSER.
  test "underscores in the search term are literal, not wildcards" do
    record(id: "c1", action: "config.set", scope: "runa", name: "pg", status: "succeeded",
      config_keys: [{"key" => "PGXSHAREDXUSER", "value_digest" => "aa11"}])

    get activity_path(server_key: @key, q: "PG_SHARED_USER")

    assert_response :success
    assert_includes response.body, "No actions match these filters"
  end

  test "the search composes with the other filters instead of replacing them" do
    # Distinct names, because "apply" and "delete" also appear as options in
    # the Action dropdown — asserting on those would be reading the filter bar
    # and calling it the table.
    record(id: "a1", action: "apply", scope: "runa", status: "succeeded", name: "applyonly")
    record(id: "a2", action: "delete", scope: "runa", status: "succeeded", name: "deleteonly")

    get activity_path(server_key: @key, q: "runa", act: "delete")

    assert_response :success
    assert_includes response.body, "deleteonly"
    refute_includes response.body, "applyonly"
  end

  # The range form and the dropdown form each carry the other's state. Miss the
  # query in either and touching a filter silently discards the search.
  test "both filter forms carry the search term" do
    get activity_path(server_key: @key, q: "rabbitmq", range: "24h")

    assert_response :success

    body = response.body

    # Echoed into the box itself...
    assert_includes body, 'name="q" value="rabbitmq"'
    # ...and carried by the range form as a hidden field.
    assert_includes body, 'value="rabbitmq"'
    assert_includes body, 'name="range" value="24h"'
  end

  test "the page names the server it is showing" do
    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, @server.name
  end

  test "the turbo frame request renders only the table" do
    record(id: "a1", action: "apply", status: "succeeded", name: "checkoutsvc")

    get activity_path(server_key: @key), headers: {"Turbo-Frame" => ActivityController::FRAME}

    assert_response :success
    assert_includes response.body, "checkoutsvc"
    # No dashboard chrome: the frame swap must not repaint the sidebar.
    refute_includes response.body, "<aside"
  end

  test "a scope link keeps the other filters and drops the page" do
    record(id: "a1", action: "apply", origin: "cli", scope: "runa", status: "succeeded", name: "checkoutsvc")

    get activity_path(server_key: @key, origin: "cli", page: 1)

    assert_response :success
    assert_includes response.body, "scope=runa"
    assert_includes response.body, "origin=cli"
  end

  # A cursor from a mangled or shared URL reaches a WHERE clause. Anything that
  # is not exactly two integers has to fall back to the newest page rather than
  # become a query.
  test "a malformed cursor falls back to the newest page" do
    record(id: "a1", action: "apply", status: "succeeded", name: "checkoutsvc")

    ["not-a-cursor", "1; DROP TABLE activity_actions", "", "12:"].each do |bad|
      get activity_path(server_key: @key, after: bad)

      assert_response :success
      assert_includes response.body, "checkoutsvc"
    end
  end

  # THE reason for cursor paging. This list grows at the TOP while you read it:
  # the poller inserts every thirty seconds and the frame reloads itself. Under
  # OFFSET everything shifts down, so page two re-shows rows already read on
  # page one. A cursor names a row, and a row does not move.
  test "rows arriving at the top do not shift the next page" do
    (1..ActivityPageData::PER_PAGE).each do |i|
      record(id: "old#{i}", action: "apply", status: "succeeded", name: "page1svc#{i}",
        at: Time.utc(2026, 6, 16, 10, 0, i))
    end

    record(id: "tail", action: "apply", status: "succeeded", name: "tailsvc",
      at: Time.utc(2026, 6, 16, 9, 0, 0))

    get activity_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "page1svc1"
    refute_includes response.body, "tailsvc"

    cursor = ActivityAction.recent_first.limit(ActivityPageData::PER_PAGE).last.cursor

    # The poller lands five newer actions between the two page views.
    (1..5).each do |i|
      record(id: "fresh#{i}", action: "apply", status: "succeeded", name: "freshsvc#{i}",
        at: Time.utc(2026, 6, 16, 11, 0, i))
    end

    get activity_path(server_key: @key, after: cursor)

    assert_response :success
    assert_includes response.body, "tailsvc"

    # Under OFFSET the five new rows would have pushed five of page one down
    # into page two. Under a cursor, nothing that was on page one is here.
    refute_includes response.body, "page1svc1"
    refute_includes response.body, "freshsvc1"
  end

  test "paging forward and back returns to the same set" do
    (1..ActivityPageData::PER_PAGE + 2).each do |i|
      record(id: "a#{i}", action: "apply", status: "succeeded", name: "svc#{i}",
        at: Time.utc(2026, 6, 16, 10, 0, i))
    end

    first_page = ActivityAction.recent_first.limit(ActivityPageData::PER_PAGE).to_a

    get activity_path(server_key: @key, after: first_page.last.cursor)

    assert_response :success
    assert_includes response.body, "svc2"

    # Walking back from the second page's newest row lands on the first set.
    second_page_newest = ActivityAction.older_than(first_page.last.ts_epoch, first_page.last.id)
      .recent_first.first

    get activity_path(server_key: @key, before: second_page_newest.cursor)

    assert_response :success
    assert_includes response.body, "svc#{ActivityPageData::PER_PAGE + 2}"
  end

  # No "page N of M": a cursor names a row rather than a position, and a total
  # means counting every match on every render. The controls are the three a
  # cursor can honestly offer.
  test "the pager offers newest, previous and next but never a total" do
    (1..ActivityPageData::PER_PAGE + 1).each do |i|
      record(id: "a#{i}", action: "apply", status: "succeeded", name: "svc#{i}",
        at: Time.utc(2026, 6, 16, 10, 0, i))
    end

    get activity_path(server_key: @key)

    assert_response :success

    body = response.body

    assert_includes body, 'aria-label="Older"'
    # On the newest page there is nothing newer, so both are inert rather than
    # absent — a control that disappears moves the ones beside it.
    assert_includes body, 'aria-disabled="true"'
    refute_match(/page \d+ of \d+/i, body)
  end

  test "a single page of results draws no pager at all" do
    record(id: "a1", action: "apply", status: "succeeded", name: "checkoutsvc")

    get activity_path(server_key: @key)

    assert_response :success
    refute_includes response.body, 'aria-label="Pagination"'
  end

  test "one server's actions never appear under another" do
    other = servers(:beta)

    ActivityAction.create!(
      server_id: other.id, activity_id: "b1", config_key: "", event: "done",
      event_rank: 2, action: "delete", ts_iso: Time.current.utc.iso8601,
      payload: {"id" => "b1", "ts" => Time.current.utc.iso8601, "event" => "done",
                "action" => "delete", "name" => "leaked"}.to_json
    )

    get activity_path(server_key: @key)

    assert_response :success
    refute_includes response.body, "leaked"
  end
end
