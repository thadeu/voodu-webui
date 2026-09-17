# frozen_string_literal: true

require "test_helper"

# Editing a pod's environment where it is read.
#
# The property that decides most of this file: the container's env mixes two
# origins the payload does not distinguish — variables the IMAGE declares
# (PATH, LANG) and variables an operator set through voodu. They are changed by
# different acts, so the screen must not offer the same button for both.
class PodEnvControllerTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"
  POD = "runa-pg.0"
  SECRET = "postgres://user:hunter2@db/prod"

  setup do
    @server = servers(:alpha)

    # The warehouse row is what names the bucket. Parsing the container name
    # would guess, and a wrong guess aims a WRITE at another app's bucket.
    #
    # The payload carries the env because PodDetailData reads the WAREHOUSE,
    # not the box — an empty payload here renders a card with no rows, and the
    # card assertions would fail for a reason that has nothing to do with them.
    @pod = Pod.create!(
      server: @server, container_name: POD, kind: "deployment",
      scope: "runa", resource_name: "pg", synced_at: Time.current,
      payload: {
        "name" => POD, "scope" => "runa", "resource_name" => "pg",
        "env" => {"PATH" => "/usr/bin", "BACKUP_KEEP" => "7"},
        # Labels too: the card beside Environment renders its empty state
        # without them, and a test about the PAIR would then only ever see one
        # of them.
        "labels" => {"voodu.scope" => "runa", "voodu.name" => "pg"}
      }.to_json
    )
  end

  # ── the drawer ─────────────────────────────────────────────────────────

  test "the add drawer names the bucket the write lands in" do
    stub_keys([])

    get new_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD)

    assert_response :success
    assert_match(/add a variable/i, response.body)
    assert_includes response.body, "runa/pg"
  end

  test "editing a config key offers to reveal its current value" do
    stub_keys([{"key" => "BACKUP_KEEP", "value_digest" => "a1b2c3"}])

    get edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")

    assert_response :success
    assert_match(/edit BACKUP_KEEP/i, response.body)
    assert_includes response.body,
      reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")
  end

  # THE DISTINCTION THE WHOLE FEATURE TURNS ON. An operator who thinks they are
  # editing PATH is not: they are creating a permanent piece of configuration
  # whose effect outlives the image they were looking at.
  test "a variable from the image opens as an override and says what that means" do
    stub_keys([{"key" => "BACKUP_KEEP", "value_digest" => "a1b2c3"}])

    get edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "PATH")

    assert_response :success
    assert_match(/override PATH/i, response.body)
    assert_match(/comes from the image/i, response.body)
    assert_match(/future images/i, response.body)
  end

  # There is nothing in the bucket to reveal, so offering the eye would be a
  # button that answers "not set".
  test "an override drawer does not offer to reveal a value we do not hold" do
    stub_keys([])

    get edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "PATH")

    assert_response :success
    assert_not_includes response.body,
      reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "PATH")
  end

  # Removing is offered only for what we own. "Remove PATH" would suggest we
  # could take a variable out of somebody's image.
  test "only a config key offers to be removed" do
    stub_keys([])

    get edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "PATH")

    assert_no_match(/remove this variable/i, response.body)
  end

  # ── the reveal ─────────────────────────────────────────────────────────

  # THE VALUE IS NOT IN THE DRAWER UNTIL THIS RUNS. A form pre-filled with the
  # secret would have carried it into the page and the network panel, and the
  # eye would be decoration over something already exposed.
  test "the drawer does not carry the value before the eye is clicked" do
    stub_keys([{"key" => "DATABASE_URL", "value_digest" => "a1b2c3"}])
    stub_value("DATABASE_URL", SECRET)

    get edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "DATABASE_URL")

    assert_response :success
    assert_not_includes response.body, "hunter2"
  end

  # From a CARD ROW the answer is the container's value, out of our warehouse
  # row — that is what the card is a list of. No round trip, and an unreachable
  # box cannot turn it into a misleading "(empty)".
  test "clicking the eye on a row returns the container's value" do
    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")

    assert_response :success
    assert_includes response.body, "7"
  end

  # Revealing answers "WHICH value is this", not "recite the secret". The first
  # characters of a connection string settle the first question; a full
  # 200-character token on screen is one shoulder, one screen-share or one
  # screenshot away from being somewhere else.
  test "a revealed value is truncated on screen and whole in the copy button" do
    long = "postgres://user:hunter2@db.internal.example.com:5432/production?sslmode=require&pool=25"

    @pod.update!(payload: {"env" => {"DATABASE_URL" => long}}.to_json)

    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "DATABASE_URL")

    assert_response :success

    # The tail is not DRAWN. Scoped to the visible span, because the copy
    # button's attribute legitimately holds the whole thing — asserting
    # against the whole body would be asserting the feature away.
    shown = response.body[%r{<span class="font-voodu-mono[^"]*">([^<]*)</span>}, 1]

    assert_not_nil shown
    assert_not_includes shown, "pool=25"
    assert shown.end_with?("…"), "expected an ellipsis, got #{shown.inspect}"

    # One LINE, always: `truncate` and not `break-all`, which wrapped a long
    # value onto three lines and made the row jump every time somebody clicked
    # an eye.
    assert_includes shown_span(response.body), "truncate"
    assert_no_match(/break-all/, response.body)

    # And the copy button carries all of it — it is the only way to the whole
    # value, which is what makes truncating the other one acceptable.
    assert_includes response.body, "data-clipboard-value-value=\"#{long}\""
  end

  # The pod body reloads on every state tick with `refresh: "morph"`. Without
  # this the morph put the mask back, so a value revealed at second 28 vanished
  # at second 30 — mid-read, looking like the page fighting the operator.
  #
  # Turbo skips nodes carrying an id AND data-turbo-permanent, the same
  # mechanism that keeps an open Drawer open through the same tick.
  test "a revealed value survives the page's own refresh" do
    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")

    assert_response :success

    frame = response.body[/<turbo-frame[^>]*>/]

    assert_includes frame, 'id="pod-env-value-BACKUP_KEEP"'
    assert_includes frame, "data-turbo-permanent"
  end

  # THE FRAME THAT ACTUALLY MATTERS is the one the CARD renders, because that
  # is the element that stays in the DOM. Turbo's FrameRenderer replaces a
  # frame's contents and never copies the response frame's attributes onto the
  # live element — so marking only the revealed frame did nothing, and the
  # value still vanished on the next tick.
  test "the value frame on the page is pinned against the refresh" do
    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success

    masked = response.body[/<turbo-frame[^>]*id="pod-env-value-PATH"[^>]*>/]

    assert_not_nil masked
    assert_includes masked, "data-turbo-permanent"
  end

  # An aria-label is read aloud and shown by every inspector. Repeating the
  # value there would undo the decision to show only part of it.
  test "the copy button does not repeat the value in its aria-label" do
    long = "postgres://user:hunter2@db.internal.example.com:5432/production?sslmode=require&pool=25"

    @pod.update!(payload: {"env" => {"DATABASE_URL" => long}}.to_json)

    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "DATABASE_URL")

    aria = response.body[/aria-label="[^"]*"/]

    assert_equal 'aria-label="Copy DATABASE_URL in full"', aria
  end

  test "a short value is shown whole, with no truncation note" do
    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")

    assert_response :success
    assert_includes response.body, "7"
    assert_no_match(/\+\d+</, response.body)
  end

  # THE ONE PLACE TRUNCATION WOULD BE A BUG. The drawer's field is editable,
  # so a shortened value in it gets saved as the new value — silently
  # destroying the tail of every long secret somebody opens and re-saves.
  test "the drawer's editable field is never truncated" do
    long = "x" * 300

    stub_value("TOKEN", long)

    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD,
      key: "TOKEN", variant: "field")

    assert_response :success
    assert_includes response.body, long
    assert_no_match(/truncate/, response.body)
  end

  # From the DRAWER the answer is the bucket's, because the drawer edits the
  # bucket. Pre-filling it with the container's value would invite saving
  # something that was never in there.
  test "clicking the eye in the drawer returns the config bucket's value" do
    stub_value("DATABASE_URL", SECRET)

    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD,
      key: "DATABASE_URL", variant: "field")

    assert_response :success
    assert_includes response.body, SECRET
  end

  # The two genuinely differ — set and not yet restarted into is the everyday
  # case — and a screen that conflated them would show one while editing the
  # other.
  test "the row and the drawer can disagree, and each says its own truth" do
    stub_value("BACKUP_KEEP", "30")

    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")
    row = response.body

    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD,
      key: "BACKUP_KEEP", variant: "field")

    assert_includes row, "7"
    assert_includes response.body, "30"
  end

  test "a reveal with no key is refused rather than fetching the bucket" do
    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD)

    assert_response :bad_request
  end

  # A failed reveal must still leave a usable form: not being able to SEE the
  # current value is no reason to be unable to SET one.
  test "a reveal the box refused still leaves a field to type in" do
    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/config})
      .to_return(status: 403, body: {status: "error", error: "insufficient scope"}.to_json,
        headers: {"Content-Type" => "application/json"})

    get reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD,
      key: "X", variant: "field")

    assert_response :success
    assert_match(/config:read/i, response.body)
    assert_includes response.body, "textarea"
  end

  # ── writing ────────────────────────────────────────────────────────────

  test "saving writes to the pod's own bucket, never the scope's" do
    write = WebMock.stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/config})
      .with(query: hash_including({"scope" => "runa", "name" => "pg"}))
      .to_return(status: 200, body: {status: "ok"}.to_json,
        headers: {"Content-Type" => "application/json"})

    post pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD),
      params: {key: "BACKUP_KEEP", value: "7"}

    assert_requested write
    assert_redirected_to pod_path(org_id: ACME, server_key: @server.key, name: POD)
  end

  # The flash lives in the session store and the notice lands in a log line; a
  # value in either outlives the request that was allowed to see it.
  test "the confirmation names the key and never the value" do
    stub_write

    post pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD),
      params: {key: "DATABASE_URL", value: SECRET}

    assert_includes flash[:notice], "DATABASE_URL"
    assert_not_includes flash[:notice], "hunter2"
  end

  test "a name that is not a valid variable is refused before the box is called" do
    write = stub_write

    post pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD),
      params: {key: "9LIVES", value: "x"}

    assert_not_requested write
    assert_match(/letters, digits and underscores/i, flash[:alert])
  end

  test "removing names the key to the box" do
    removal = WebMock.stub_request(:delete, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/config})
      .with(query: hash_including({"keys" => "BACKUP_KEEP", "scope" => "runa", "name" => "pg"}))
      .to_return(status: 200, body: {status: "ok"}.to_json,
        headers: {"Content-Type" => "application/json"})

    delete pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD),
      params: {key: "BACKUP_KEEP"}

    assert_requested removal
  end

  # A pod the warehouse has not seen has no bucket we can name. Writing to one
  # we invented is exactly the failure the pod-row lookup exists to prevent.
  test "a pod we have no row for is refused rather than guessed at" do
    write = stub_write

    post pod_env_path(org_id: ACME, server_key: @server.key, pod_name: "mystery-thing.9f"),
      params: {key: "FOO", value: "bar"}

    assert_not_requested write
    assert_match(/which config bucket/i, flash[:alert])
  end

  # The tenant boundary: a container name from another org's screen finds
  # nothing here, the same way a made-up one does.
  test "a pod of another server is not writable through this server's URL" do
    Pod.create!(
      server: servers(:beta), container_name: "other-app.1", kind: "deployment",
      scope: "other", resource_name: "app", payload: "{}", synced_at: Time.current
    )

    write = stub_write

    post pod_env_path(org_id: ACME, server_key: @server.key, pod_name: "other-app.1"),
      params: {key: "FOO", value: "bar"}

    assert_not_requested write
  end

  # ── the card ───────────────────────────────────────────────────────────

  test "the pod page marks each variable's origin and offers the right action" do
    stub_keys([{"key" => "BACKUP_KEEP", "value_digest" => "a1b2c3"}])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success

    # A pencil for what voodu owns.
    assert_includes response.body,
      edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")

    # And NOTHING inline for a row the image declares. An inline button there
    # looked like editing and would have been CREATING a config key that
    # shadows the image permanently — the rare, consequential act belongs on
    # the deliberate path (Add), not under a pencil on every row.
    assert_not_includes response.body,
      edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "PATH")

    # The badge is what still tells the two apart at a glance.
    assert_match(/declared by the container image/i, response.body)
    assert_match(/set through voodu/i, response.body)
  end

  # THE PROPERTY THE WHOLE CARD WAS REBUILT FOR.
  #
  # Not "the values are masked" — masked was what it did before, in CSS, over
  # data already shipped. This asserts the values are NOT THERE: not in a
  # hidden span, not in a data attribute, not in a copy button's payload. One
  # script, one extension, or one "inspect element" now finds nothing.
  test "the pod page carries no environment value in its HTML" do
    @pod.update!(payload: {
      "name" => POD, "scope" => "runa", "resource_name" => "pg",
      "env" => {"DATABASE_URL" => SECRET, "PATH" => "/usr/local/sbin:/usr/bin"}
    }.to_json)

    stub_keys([{"key" => "DATABASE_URL", "value_digest" => "a1b2c3"}])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success

    # The keys are there — a list of names is the point of the card.
    assert_includes response.body, "DATABASE_URL"
    assert_includes response.body, "PATH"

    # The values are not, in any spelling.
    assert_not_includes response.body, SECRET
    assert_not_includes response.body, "hunter2"
    assert_not_includes response.body, "/usr/local/sbin"
    assert_not_includes response.body, CGI.escapeHTML(SECRET)
  end

  # The mask used to be one bullet per character, which drew the length of
  # every secret: eight bullets beside a token field says "that is not the
  # token you think it is", and forty says how long it is.
  test "the mask is the same width whatever the value" do
    @pod.update!(payload: {
      "env" => {"SHORT" => "a", "LONG" => "x" * 200}
    }.to_json)

    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    masks = response.body.scan(/•+/).uniq

    assert_equal 1, masks.size, "expected one mask width, saw #{masks.map(&:length).inspect}"
  end

  # Turbo 8 prefetches a link's href ON HOVER. Left on, pointing at the eye
  # would fetch the secret without a click — undoing the entire reason the
  # reveal is a request. Pinned in two places because they fail differently:
  # the meta tag can be removed by someone chasing latency, and the attribute
  # is the belt under those braces.
  test "hovering never fetches a value" do
    stub_keys([{"key" => "BACKUP_KEEP", "value_digest" => "a1b2c3"}])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success
    assert_includes response.body, '<meta name="turbo-prefetch" content="false">'

    reveal = reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")
    anchor = response.body[/<a[^>]*#{Regexp.escape(reveal)}[^>]*>/]

    assert_not_nil anchor, "the reveal link is missing"
    assert_includes anchor, 'data-turbo-prefetch="false"'
  end

  # The eye lives in the ACTIONS column beside the badge, not next to the mask
  # it replaces. A turbo frame can be targeted from anywhere, so nothing forces
  # the trigger to sit inside the cell it swaps — and everything else on this
  # dashboard puts what you can DO on the right.
  test "the eye sits beside the origin badge, outside the value frame" do
    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success

    reveal = reveal_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "PATH")
    # Attribute-order independent: `id` is not guaranteed to be the first
    # attribute on the tag, and a regex that assumed so broke the day another
    # one was added.
    frame = response.body[/<turbo-frame[^>]*id="pod-env-value-PATH".*?<\/turbo-frame>/m]

    assert_not_nil frame
    assert_not_includes frame, reveal, "the eye must not be inside the frame it replaces"

    # Eye first, badge after — WITHIN THE SAME ROW. Comparing positions across
    # the whole page compares different rows: the first "image" badge belongs
    # to whichever key sorts first, not to this one.
    row = response.body[/<div[^>]*data-key="path".*?(?=<div[^>]*data-key=|\z)/m]

    assert_not_nil row, "no row for PATH"
    assert_operator row.index(reveal), :<, row.index("Declared by the container image")
  end

  # A container with sixty variables must not push everything below it off the
  # page. Both cards cap at the same height and scroll — the same height,
  # because two cards side by side with only one capped is a row whose right
  # half runs a screen past its left.
  test "environment and labels both cap their height and scroll" do
    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success

    # The cap is on the SECTION, not on the body. Capping the body caps the
    # maximum and nothing else — a nine-row card renders at its natural height
    # while a twenty-four-row one sits at the cap, and the pair is uneven.
    # That was the bug this replaced.
    cap = Components::UI::SectionCard::MAX_H

    assert_equal 2, response.body.scan(/<section[^>]*#{Regexp.escape(cap)}/).size,
      "expected both cards to cap themselves with #{cap.inspect}"

    # And the grid stretches, so the shorter card comes up to the taller.
    assert_no_match(/grid gap-3 vmd:gap-4 items-start/, response.body)
  end

  # `min-h-0` at every level of the chain is not decoration: a flex child's
  # default `min-height: auto` refuses to shrink below its content, so without
  # it the list ignores the cap and the card grows anyway.
  test "the scrolling list can actually shrink below its content" do
    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    card = response.body[/Environment ·.*/m]

    assert_includes card, Components::UI::SectionCard::SCROLL_CHAIN
    assert_includes card, Components::UI::SectionCard::SCROLL_LIST
  end

  # The search input must not scroll away from the list it filters.
  test "the filter bar stays outside the scrolling area" do
    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    # Scoped to the Environment card. Labels renders first and has its own
    # scroller, so comparing positions across the whole page compares one
    # card's filter bar against the other card's scroll container.
    card = response.body[/Environment ·.*/m]
    scroller = %(<div class="#{Components::UI::SectionCard::SCROLL_LIST}">)

    assert_includes card, scroller
    assert_operator card.index("filter keys…"), :<, card.index(scroller)
  end

  # Both cards are key/value lists of similar rhythm, so the width is better
  # spent on two columns than on one with a screen of nothing beside it.
  test "environment and labels share a row above the breakpoint" do
    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success

    assert_match(/grid gap-3 vmd:gap-4/, response.body)

    # Labels first: it is the short card, so the left column ends and you move
    # on instead of scrolling two dozen variables past a card that stopped six
    # rows in.
    # The titles are uppercased by CSS, so the markup holds them cased.
    assert_operator response.body.index("Labels ·"), :<, response.body.index("Environment ·")
  end

  test "the pod page offers to add a variable" do
    stub_keys([])

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success
    assert_includes response.body, new_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD)
  end

  # A card drawing a pencil a member cannot use is a door we drew ourselves.
  test "a member sees the values masked and no way to change them" do
    stub_keys([{"key" => "BACKUP_KEEP", "value_digest" => "a1b2c3"}])

    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    get pod_path(org_id: ACME, server_key: @server.key, name: POD)

    assert_response :success
    assert_not_includes response.body, new_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD)
    assert_not_includes response.body,
      edit_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD, key: "BACKUP_KEEP")
  end

  # nil provenance is a THIRD state, not "everything is from the image". The
  # drawer variant does not spend a round trip on it, and labeling rows there
  # would be stating something never checked.
  test "the drawer variant of the pod page claims no origin it did not check" do
    get pod_path(org_id: ACME, server_key: @server.key, name: POD, embed: 1)

    assert_response :success
    assert_not_includes response.body, "Declared by the container image"
  end

  # ── authorization ──────────────────────────────────────────────────────

  test "a member cannot write env by posting directly" do
    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    write = stub_write

    post pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD),
      params: {key: "FOO", value: "bar"}

    assert_not_requested write
  end

  test "a member does not reach the drawer" do
    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    get new_pod_env_path(org_id: ACME, server_key: @server.key, pod_name: POD)

    assert_not_equal 200, response.status
  end

  private

  # The visible value span, opening tag included, so a test can assert on the
  # classes it carries as well as on the text it does not.
  def shown_span(body)
    body[%r{<span class="font-voodu-mono[^"]*"[^>]*>[^<]*</span>}] || ""
  end

  def stub_keys(keys)
    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/config})
      .with(query: hash_including({"values" => "false"}))
      .to_return(status: 200, body: {status: "ok", data: {redacted: true, keys: keys}}.to_json,
        headers: {"Content-Type" => "application/json"})
  end

  def stub_value(key, value)
    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/config})
      .with(query: hash_including({"key" => key}))
      .to_return(status: 200, body: {status: "ok", data: {key => value}}.to_json,
        headers: {"Content-Type" => "application/json"})
  end

  def stub_write
    WebMock.stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/config})
      .to_return(status: 200, body: {status: "ok"}.to_json,
        headers: {"Content-Type" => "application/json"})
  end
end
