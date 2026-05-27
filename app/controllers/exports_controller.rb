# frozen_string_literal: true

# ExportsController — operator-triggered log dumps from the local
# warehouse.
#
# Lifecycle:
#
#   POST  /exports          create — enqueues LogExportJob
#   GET   /exports/:id      show   — drawer body (Turbo Stream target)
#   GET   /exports/:id/download    — send_file the artifact
#
# Authorization: every action is implicitly scoped to current_island
# (resolved by ApplicationController from params[:tenant_key]), and
# we double-check `export.island_id == current_island.id` before
# serving — otherwise an operator could enumerate ids across
# islands by guessing.
class ExportsController < ApplicationController
  before_action :require_current_island
  before_action :find_export, only: %i[show download]

  # new — returns the drawer body (the export form). Fetched lazily
  # by the Drawer component on first open. Pre-fills the pod picker
  # with current_island's pods (grouped by kind) + reads the
  # operator's current pod context from `?pod=` for smart defaults.
  def new
    drawer = Components::Logs::ExportDrawer.new(
      pods:           pods_grouped_by_kind,
      current_pod:    params[:pod],
      current_island: current_island,
      # Last 5 exports for this island — surfaces in the drawer
      # header so the operator can grab downloads they generated
      # earlier (even if they closed the drawer mid-job).
      recent_exports: current_island.log_exports.recent.limit(5).to_a
    )

    respond_to do |format|
      # HTML branch — drawer_controller's lazy fetch (`Accept:
      # text/html`). Bare body markup so the injected innerHTML
      # doesn't nest <html>/<head>. Same idiom logs#show uses.
      format.html { render(drawer, layout: false) }

      # turbo_stream branch — fires when the operator clicks the
      # "New export" button on the ExportStatus block. We update
      # the drawer body in place (target id="log-export-drawer-body")
      # so the operator returns to the filter form WITHOUT closing
      # the drawer first.
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "log-export-drawer-body",
          drawer.call
        )
      end
    end
  end

  # create — receive form POST from Components::Logs::ExportDrawer,
  # build the params hash, persist a queued LogExport, fire the
  # job, and respond with a redirect to #show so the drawer body
  # starts rendering the status. The drawer JS picks up the
  # Turbo Stream channel from the show page on its own.
  def create
    export_params = build_params_hash

    export = LogExport.new(
      island_id: current_island.id,
      status:    "queued"
    )
    export.params_hash = export_params
    export.save!

    LogExportJob.perform_later(export.id)

    respond_to do |format|
      format.html { redirect_to export_path(id: export.id) }
      format.turbo_stream do
        # Caller fetched the drawer body via XHR (drawer_controller.js).
        # Re-render the body with the new export id so the form
        # disappears and the status block takes over.
        render turbo_stream: turbo_stream.update(
          "log-export-drawer-body",
          Components::Logs::ExportStatus.new(export: export).call
        )
      end
    end
  end

  # show — renders the drawer body for the given export. Two modes:
  #
  #   - HTML (operator hit "open in new tab"): full-page wrapper
  #     so they can see the export details standalone.
  #   - Embed (drawer_controller's lazy fetch, `X-Drawer-Embed: 1`):
  #     chrome-less body so it slots into the drawer panel.
  #
  # Either way, the rendered body subscribes to the export's
  # turbo-stream channel so subsequent state changes (running →
  # ready) morph in place without a page reload.
  def show
    view = Views::Exports::Show.new(
      **dashboard_context.merge(
        export: @export,
        embed:  embed_request?
      )
    )

    # Same idiom as logs#show — embed mode skips the layout so the
    # drawer's innerHTML inject doesn't end up with nested <html>.
    embed_request? ? render(view, layout: false) : render(view)
  end

  # download — send_file the on-disk artifact. Increments
  # downloaded_at as a hint to the cleanup job (the file still
  # lives for the full 24h TTL regardless — operator can re-download
  # if they need to).
  def download
    unless @export.ready? && @export.absolute_file_path && File.exist?(@export.absolute_file_path)
      redirect_to export_path(id: @export.id), alert: "Export not ready for download."
      return
    end

    @export.update_column(:downloaded_at, Time.current) if @export.downloaded_at.nil?

    send_file(
      @export.absolute_file_path,
      filename:    download_filename(@export),
      type:        download_mime(@export),
      disposition: "attachment"
    )
  end

  private

  def find_export
    @export = LogExport.find_by(id: params[:id], island_id: current_island.id)
    return if @export

    redirect_to logs_path, alert: "Export not found." and return
  end

  def require_current_island
    return if current_island

    redirect_to root_path, alert: "Select a server first."
  end

  # build_params_hash — normalise the form params into the JSON
  # shape LogExport.params_hash expects. Defensive against missing
  # keys; everything is optional and has a sensible default.
  #
  # NOTE: the form submits `output_format` (not `format`) because
  # `format` is reserved in Rails — it'd be interpreted as the
  # request's format override and 406 if no Mime matches. We map
  # it here to the internal `"format"` key the rest of the
  # pipeline (LogExport, LogExportJob, ExportStatus) reads.
  def build_params_hash
    raw = params.permit(
      :from, :until, :content_search, :regex, :group_by_pod, :output_format,
      pods: []
    )

    {
      "from"           => raw[:from].presence,
      "until"          => raw[:until].presence,
      "pods"           => Array(raw[:pods]).compact.reject(&:empty?),
      "content_search" => raw[:content_search].to_s,
      "regex"          => truthy?(raw[:regex]),
      "group_by_pod"   => truthy?(raw[:group_by_pod]),
      "format"         => raw[:output_format].presence || "ndjson"
    }
  end

  def truthy?(value)
    %w[1 true yes on].include?(value.to_s.downcase)
  end

  # download_filename + download_mime — both branch on whether the
  # export is a zip (group_by_pod=true) or a single file. The single-
  # file extension matches the operator-chosen format (ndjson/txt/csv);
  # the zip always wraps multiple files of that format inside.
  def download_filename(export)
    ext = export.group_by_pod? ? "zip" : export.format
    "logs-#{current_island.key}-#{export.id}.#{ext}"
  end

  FORMAT_MIME = {
    "ndjson" => "application/x-ndjson",
    "txt"    => "text/plain; charset=utf-8",
    "csv"    => "text/csv; charset=utf-8"
  }.freeze

  def download_mime(export)
    return "application/zip" if export.group_by_pod?

    FORMAT_MIME[export.format] || "application/octet-stream"
  end

  # pods_grouped_by_kind — returns { "deployment" => [pod, ...],
  # "statefulset" => [...], "job" => [...], "cronjob" => [...] }
  # for the picker. Reads from the warehouse (current_island.pods),
  # so only currently-known pods show up. Historical pods that
  # still have NDJSON on disk but aren't in the current snapshot
  # can be reached via "All pods" mode.
  def pods_grouped_by_kind
    return {} unless current_island

    current_island.pods.order(:container_name).group_by(&:kind)
  end

  # embed_request? — true when the Drawer's Stimulus controller
  # fetched this URL (it sets ?embed=1 and X-Drawer-Embed: 1 for
  # redundancy). Drives Views::Exports::Show into chrome-less mode.
  def embed_request?
    params[:embed].to_s == "1" ||
      request.headers["X-Drawer-Embed"].to_s == "1"
  end
end
