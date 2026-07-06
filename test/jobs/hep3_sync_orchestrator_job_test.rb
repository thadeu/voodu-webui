# frozen_string_literal: true

require "test_helper"

# Hep3SyncOrchestratorJob fans out one poller per (server, reader),
# DEMAND-DRIVEN: the readers come from the Table panels on the server's
# dashboards (MetricDashboard.table_readers_for), gated on the plugin
# being installed. These pin that gate + the demand wiring — adding a
# hep3 Table panel is what turns the poller on for that reader.
class Hep3SyncOrchestratorJobTest < ActiveJob::TestCase
  fixtures :orgs, :servers

  def install_hep3(server)
    System.create!(
      server: server,
      payload: {host: {}, plugins: [{"name" => "hep3", "aliases" => ["hep"]}]}.to_json,
      synced_at: Time.current
    )
  end

  # table_panel — a hep3 Table panel bound to `server` (M2: the poller demand
  # follows panel["server_id"], so the reader is enqueued for THAT server).
  def table_panel(server:, scope:, name:, source: "hep3")
    {
      "scope_kind" => "table", "chart_type" => "table", "source" => source,
      "server_id" => server.id, "scope" => scope, "name" => name, "view" => "messages",
      "label" => "SIP", "color" => "var(--voodu-accent)"
    }
  end

  test "enqueues a poller per hep3 table reader, only with the plugin installed" do
    alpha = servers(:alpha)
    install_hep3(alpha)
    alpha.org.metric_dashboards.create!(name: "sip", panels: [table_panel(server: alpha, scope: "fsw", name: "hep3-api")])

    assert_enqueued_with(job: Hep3PollerJob, args: [alpha.id, "fsw", "hep3-api"]) do
      Hep3SyncOrchestratorJob.perform_now
    end

    assert_enqueued_jobs 1, only: Hep3PollerJob
  end

  test "dedups a reader referenced by panels on multiple dashboards" do
    alpha = servers(:alpha)
    install_hep3(alpha)
    alpha.org.metric_dashboards.create!(name: "a", panels: [table_panel(server: alpha, scope: "fsw", name: "hep3-api")])
    alpha.org.metric_dashboards.create!(name: "b", panels: [table_panel(server: alpha, scope: "fsw", name: "hep3-api")])

    assert_enqueued_jobs 1, only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end

  test "skips a hep3 table panel when the plugin is not installed" do
    servers(:alpha).then { |a| a.org.metric_dashboards.create!(name: "sip", panels: [table_panel(server: a, scope: "fsw", name: "hep3-api")]) }
    # no System snapshot → plugin_installed?("hep3") is false

    assert_no_enqueued_jobs only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end

  test "ignores non-hep3 table panels and non-table panels" do
    alpha = servers(:alpha)
    install_hep3(alpha)
    metric = {"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
              "label" => "CPU", "color" => "c", "server_id" => alpha.id}
    alpha.org.metric_dashboards.create!(
      name: "mix",
      panels: [metric, table_panel(server: alpha, scope: "fsw", name: "other", source: "elsewhere")]
    )

    assert_no_enqueued_jobs only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end
end
