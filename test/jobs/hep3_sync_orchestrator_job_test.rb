# frozen_string_literal: true

require "test_helper"

# Hep3SyncOrchestratorJob fans out one poller per (island, reader),
# DEMAND-DRIVEN: the readers come from the Table panels on the island's
# dashboards (MetricDashboard.table_readers_for), gated on the plugin
# being installed. These pin that gate + the demand wiring — adding a
# hep3 Table panel is what turns the poller on for that reader.
class Hep3SyncOrchestratorJobTest < ActiveJob::TestCase
  fixtures :orgs, :islands

  def install_hep3(island)
    System.create!(
      island: island,
      payload: {host: {}, plugins: [{"name" => "hep3", "aliases" => ["hep"]}]}.to_json,
      synced_at: Time.current
    )
  end

  # table_panel — a hep3 Table panel bound to `island` (M2: the poller demand
  # follows panel["island_id"], so the reader is enqueued for THAT server).
  def table_panel(island:, scope:, name:, source: "hep3")
    {
      "scope_kind" => "table", "chart_type" => "table", "source" => source,
      "island_id" => island.id, "scope" => scope, "name" => name, "view" => "messages",
      "label" => "SIP", "color" => "var(--voodu-accent)"
    }
  end

  test "enqueues a poller per hep3 table reader, only with the plugin installed" do
    alpha = islands(:alpha)
    install_hep3(alpha)
    alpha.org.metric_dashboards.create!(name: "sip", panels: [table_panel(island: alpha, scope: "fsw", name: "hep3-api")])

    assert_enqueued_with(job: Hep3PollerJob, args: [alpha.id, "fsw", "hep3-api"]) do
      Hep3SyncOrchestratorJob.perform_now
    end

    assert_enqueued_jobs 1, only: Hep3PollerJob
  end

  test "dedups a reader referenced by panels on multiple dashboards" do
    alpha = islands(:alpha)
    install_hep3(alpha)
    alpha.org.metric_dashboards.create!(name: "a", panels: [table_panel(island: alpha, scope: "fsw", name: "hep3-api")])
    alpha.org.metric_dashboards.create!(name: "b", panels: [table_panel(island: alpha, scope: "fsw", name: "hep3-api")])

    assert_enqueued_jobs 1, only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end

  test "skips a hep3 table panel when the plugin is not installed" do
    islands(:alpha).then { |a| a.org.metric_dashboards.create!(name: "sip", panels: [table_panel(island: a, scope: "fsw", name: "hep3-api")]) }
    # no System snapshot → plugin_installed?("hep3") is false

    assert_no_enqueued_jobs only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end

  test "ignores non-hep3 table panels and non-table panels" do
    alpha = islands(:alpha)
    install_hep3(alpha)
    metric = {"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
              "label" => "CPU", "color" => "c", "island_id" => alpha.id}
    alpha.org.metric_dashboards.create!(
      name: "mix",
      panels: [metric, table_panel(island: alpha, scope: "fsw", name: "other", source: "elsewhere")]
    )

    assert_no_enqueued_jobs only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end
end
