# frozen_string_literal: true

# Views::Hep3::Index — the /hep3 page: the SIP calls of ONE voodu-hep3 reader.
#
# Two states, both under the same range picker (the window is always set):
#   no reader chosen — the ReaderPicker: reader cards + the optional filter,
#                      nothing is fetched yet.
#   reader chosen    — a Metrics-style grid of two panels: the distinct-calls
#                      count (polled) and the Calls TableCard (columns,
#                      refresh, live, call-flow — the same component as on
#                      Metrics, so the two never drift).
#
# The grid is the Metrics one (metrics-display + the Settings drawer): hide,
# reorder, resize and pick columns, stored under kind "hep3". The filter (`q`,
# set in the picker) filters BOTH panels and lives in the URL like every other
# state of the tab; the subtitle shows it, "Change reader" edits it.
#
# The call-flow host sits outside the table, at page level, like on Metrics and
# Logs: the row icon dispatches `datatable:rowaction` and the host injects the
# SIP ladder modal.
class Views::Hep3::Index < Views::Base
  def initialize(current_path:, servers: [], current_server: nil, data: nil)
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @data = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, current_server: @current_server,
      breadcrumb: overview_crumbs({label: "HEP3"})
    ) do
      if @current_server.nil? || @data.nil?
        render Components::UI::NoServerState.new
      else
        body

        render Components::Hep3::CallFlowHost.new(
          call_url: metrics_hep3_call_path(server_key: @current_server.key)
        )
      end
    end
  end

  private

  def body
    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5") do
      render Components::UI::WorkspaceTabs.new(
        storage_key: "voodu:hep3-tabs:#{@current_server.key}",
        tab_id: @data.tab_id,
        label: @data.tab_label,
        base_path: hep3_path,
        prefs_prefix: Hep3PageData::TABLE_KEY_PREFIX,
        fresh: @data.fresh?
      ) { tab_content }
    end
  end

  def tab_content
    page_head
    toolbar

    if @data.readers.empty?
      no_readers
    elsif @data.selected?
      panels
    else
      render Components::Hep3::ReaderPicker.new(
        readers: @data.readers,
        hidden_params: tab_params,
        filter_query: @data.filter_query,
        fields: Hep3PageData.filter_fields
      )
    end
  end

  def page_head
    render(
      Components::UI::PageHeader.new(title: "HEP3")
        .with_subtitle { page_sub }
    )
  end

  def page_sub
    span(class: "inline-flex flex-wrap items-center gap-1.5") do
      plain "SIP calls captured by voodu-hep3"

      if @data.selected?
        span(class: "text-voodu-muted-2") { "·" }
        span(class: "font-voodu-mono text-voodu-text-2") { "#{@data.selected[:scope]} · #{@data.selected[:name]}" }
      end

      if @data.selected? && @data.filter_query.present?
        span(class: "text-voodu-muted-2") { "·" }
        span(
          title: @data.filter_query,
          class: "inline-flex items-center gap-1 max-w-full min-w-0 px-1.5 h-5 border border-voodu-border bg-voodu-surface font-voodu-mono text-[11px] text-voodu-text-2"
        ) do
          render Icon::FunnelOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted")
          span(class: "truncate") { @data.filter_query }
        end
      end
    end
  end

  # toolbar — range on the left, the reader switch on the right. Stacks on
  # mobile: the range pills alone already fill a 360px row.
  def toolbar
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2.5") do
      render Components::Metrics::RangePicker.new(
        range: @data.range,
        custom: @data.custom?,
        from_iso: request.query_parameters[:from],
        until_iso: request.query_parameters[:until],
        extra_params: request.query_parameters.slice(:scope, :name, :q).merge(ws: @data.tab_id),
        base_path: hep3_path
      )

      if @data.selected?
        div(class: "flex items-center gap-2 vmd:ml-auto") do
          change_reader

          render Components::Metrics::DisplaySettingsButton.new(
            kind: "hep3", scope_kind: "host", display_settings_url: hep3_display_settings_path
          )
        end
      end
    end
  end

  def panels
    div(class: "flex flex-col gap-4", data: {controller: "metrics-display", metrics_display_kind_value: "hep3"}) do
      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3", data: {metrics_display_target: "grid"}) do
        render Components::Hep3::CountCard.new(
          data: @data,
          src: hep3_count_path(**request.query_parameters.symbolize_keys, ws: @data.tab_id),
          metric: Hep3PageData::COUNT_PANEL
        )

        calls_table
      end
    end
  end

  # change_reader — back to the picker, keeping the window and the filter (it
  # is edited there). Shown even with one reader: it is the way to the filter.
  def change_reader
    a(
      href: hep3_path(**tab_params),
      class: "inline-flex items-center justify-center gap-1.5 px-2.5 h-8 vmd:ml-auto self-start vmd:self-auto " \
             "border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11.5px] font-medium " \
             "hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"
    ) do
      render Icon::ArrowsRightLeftOutline.new(class: "w-3.5 h-3.5")
      span { "Change reader" }
    end
  end

  def calls_table
    reader = @data.selected

    render Components::Metrics::TableCard.new(
      label: "#{reader[:scope]} · #{reader[:name]} — calls",
      color: "var(--voodu-text-2)",
      source: "hep3",
      scope: reader[:scope],
      name: reader[:name],
      view: Hep3PageData::VIEW,
      fields: @data.fields,
      default_fields: @data.default_fields,
      filter_query: @data.filter_query,
      rows_url: metrics_datatable_rows_path(source: "hep3"),
      row_action: @data.row_action,
      server_id: @current_server.id,
      range: @data.custom? ? "custom" : @data.range,
      window_from: (@data.custom? ? request.query_parameters[:from] : nil),
      window_until: (@data.custom? ? request.query_parameters[:until] : nil),
      key: @data.table_key,
      metric: Hep3PageData::TABLE_PANEL,
      tall: true
    )
  end

  # no_readers — the plugin is installed but no reader runs. Says what to
  # deploy, because "no data" alone reads like a broken page.
  def no_readers
    div(class: "border border-dashed border-voodu-border bg-voodu-surface px-4 py-10 flex flex-col items-center gap-2 text-center") do
      render Icon::PhoneXMarkOutline.new(class: "w-6 h-6 text-voodu-muted")
      p(class: "m-0 text-[13px] font-semibold text-voodu-text") { "No HEP3 reader is running on this server" }
      p(class: "m-0 text-[12px] text-voodu-muted max-w-md") do
        plain "Deploy a hep3 resource (a voodu-hep3-api reader) to capture SIP calls. Its calls show here when it runs."
      end
    end
  end

  # tab_params — what the picker keeps: this tab, its window and its filter.
  def tab_params
    request.query_parameters.slice(:range, :from, :until, :q).symbolize_keys.merge(ws: @data.tab_id)
  end
end
