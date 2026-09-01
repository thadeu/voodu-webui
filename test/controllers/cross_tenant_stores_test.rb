# frozen_string_literal: true

require "test_helper"

# The three stores that hold a bare server_id and nothing else.
#
# Everything in the primary database carries an org_id and a foreign key, so a
# scoping slip there tends to surface as a broken query. These do not: the
# metrics warehouse and the HEP tables live in their OWN databases (no cross-DB
# association is even possible), and the logs are files on disk whose only
# tenant marker is a directory name. Nothing downstream of a wrong server_id
# could notice it was wrong.
#
# So the guarantee has to be proved from the outside, and the only proof that
# counts is: put tenant B's data in, ask as tenant A, and show it never comes
# back. ServerScoped and the architecture lint are the locks; this is the test
# that the locks are on the right doors.
#
# Each store gets a marker string that appears NOWHERE else, so an assertion
# cannot pass because the response happened to be empty for another reason —
# every test also proves the attacker's OWN data reads back, which is what
# distinguishes "isolated" from "broken".
class CrossTenantStoresTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"
  GLOBEX = "globex22"

  FOREIGN = "globex-secret-payload"
  OWN = "acme-own-payload"

  setup do
    @alpha = servers(:alpha)   # acme — the attacker's
    @gamma = servers(:gamma)   # globex — the victim's

    sign_out
    sign_in_as(email: users(:owner).email) # owner of acme, and nothing in globex
  end

  teardown do
    [@alpha, @gamma].each { |s| clear_logs(s) }
  end

  # ── The metrics warehouse (its own database, no org column) ────────────

  # Asserted on the overview, because that is where a warehouse sample actually
  # surfaces as text. The chart endpoint answers 302 with an empty body outside
  # a turbo frame, so asserting absence there proves nothing — a leak and a
  # redirect look identical.
  #
  # Both values are distinctive and both are checked: without the positive half
  # this passes just as well when the page renders no metrics at all.
  FOREIGN_CPU = "93.7"
  OWN_CPU = "11.3"

  test "another org's metric samples never reach the overview" do
    seed_metric(@gamma, FOREIGN_CPU)
    seed_metric(@alpha, OWN_CPU)

    get server_root_path(org_id: ACME, server_key: @alpha.key)

    assert_response :success
    assert_includes @response.body, OWN_CPU, "the attacker's own sample must read back"
    assert_not_includes @response.body, FOREIGN_CPU
  end

  # The watermark endpoint takes a raw id. It is machine-authenticated, but an
  # id naming nothing must say so rather than answer 0 as if the warehouse were
  # simply empty.
  test "the poller watermark refuses an id that names no server" do
    ENV["POLLER_TOKEN"] = "test-internal-token-aaaaaaaaaaaaaaaa"

    get internal_poller_metrics_watermark_path(server_id: 999_999),
      headers: {"X-Voodu-Internal-Token" => ENV.fetch("POLLER_TOKEN")}

    assert_response :not_found
  ensure
    ENV.delete("POLLER_TOKEN")
  end

  # ── The HEP tables (their own database, no org column) ─────────────────

  test "another org's SIP capture never reaches the datatable" do
    seed_hep(@gamma, FOREIGN)
    seed_hep(@alpha, OWN)

    get metrics_datatable_rows_path(
      org_id: ACME, server_key: @alpha.key,
      source: "hep3", scope: "fsw", name: "hep3-api", view: "messages"
    )

    assert_response :success
    assert_includes @response.body, OWN, "the attacker's own rows must still read back"
    assert_not_includes @response.body, FOREIGN
  end

  test "a forged server_id cannot pull another org's SIP capture" do
    seed_hep(@gamma, FOREIGN)

    get metrics_datatable_rows_path(
      org_id: ACME, server_key: @alpha.key,
      source: "hep3", scope: "fsw", name: "hep3-api", view: "messages",
      server_id: @gamma.id
    )

    assert_response :not_found
    assert_not_includes @response.body, FOREIGN
  end

  test "another org's call flow is not reachable by call id" do
    seed_hep(@gamma, FOREIGN, call_id: "victim-call-1")

    get metrics_hep3_call_path(
      org_id: ACME, server_key: @alpha.key, call_id: "victim-call-1"
    )

    assert_not_includes @response.body.to_s, FOREIGN
  end

  # ── The NDJSON log tree (files on disk, tenant = a directory name) ──────

  test "another org's log lines never reach the log viewer" do
    seed_log(@gamma, "web", FOREIGN)
    seed_log(@alpha, "web", OWN)

    get logs_analytics_path(org_id: ACME, server_key: @alpha.key)

    assert_response :success
    assert_includes @response.body, OWN, "the attacker's own lines must still read back"
    assert_not_includes @response.body, FOREIGN
  end

  test "another org's log lines never reach the search stream" do
    seed_log(@gamma, "web", FOREIGN)
    seed_log(@alpha, "web", OWN)

    get logs_warehouse_stream_path(org_id: ACME, server_key: @alpha.key, q: "payload")

    assert_includes @response.body, OWN, "the attacker's own lines must still read back"
    assert_not_includes @response.body, FOREIGN
  end

  test "another org's log lines never reach the export" do
    seed_log(@gamma, "web", FOREIGN)
    seed_log(@alpha, "web", OWN)

    get logs_analytics_export_path(org_id: ACME, server_key: @alpha.key, format: :json)

    assert_includes @response.body, OWN, "the attacker's own lines must still export"
    assert_not_includes @response.body, FOREIGN
  end

  # The server segment of the path is the tenant boundary ON DISK, and it had no
  # sanitisation — the pod segment goes through safe_pod_name, this one did not.
  test "the log path refuses anything that is not a Server" do
    assert_raises(ArgumentError) { LogTail::FilePath.server_dir(@gamma.id) }
    assert_raises(ArgumentError) { LogTail::FilePath.server_dir("../#{@gamma.id}") }
  end

  # ── The whole point, stated once ───────────────────────────────────────

  # None of the three can be reached with an id alone any more. If this fails,
  # some caller is passing an Integer again and the boundary is back to being a
  # convention.
  test "every store refuses a bare id at its entry point" do
    id = @gamma.id

    assert_raises(ArgumentError) { MetricSample.last_ts_for(id) }
    assert_raises(ArgumentError) { HepMessage.for_instance(server: id, scope: "fsw", name: "x").to_a }
    assert_raises(ArgumentError) { HepCursor.cursor_for(id, "fsw", "hep3-api") }
    assert_raises(ArgumentError) { LogTail::FilePath.list_pods(id) }
  end

  private

  def seed_metric(server, cpu)
    iso = 2.minutes.ago.utc.iso8601

    MetricSample.bulk_insert([{
      server_id: server.id, source: "system", ts_iso: iso,
      payload: {source: "system", ts: iso, name: "host", cpu_percent: cpu.to_f}.to_json
    }])
  end

  def seed_hep(server, marker, call_id: "x")
    payload = {ts: "2026-06-30 10:00:05.000000", call_id: call_id, x_cid: "", method: "INVITE",
               response_code: 0, from_user: marker, raw_sip: "R"}.to_json

    HepMessage.bulk_insert([{server_id: server.id, scope: "fsw", name: "hep3-api", payload: payload}])
  end

  def seed_log(server, pod, marker)
    time = 2.minutes.ago.utc
    path = LogTail::FilePath.daily_file(server, pod, time.to_date)
    LogTail::FilePath.ensure_dir(File.dirname(path))

    row = {ts: time.iso8601(3), pod: pod, stream: "stdout", level: nil,
           msg: marker, raw: marker, parsed: false}

    File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
  end

  def clear_logs(server)
    dir = LogTail::FilePath.server_dir(server)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
