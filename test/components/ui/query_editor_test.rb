# frozen_string_literal: true

require "test_helper"

class Components::UI::QueryEditorTest < ActiveSupport::TestCase
  def render_editor(**opts)
    Components::UI::QueryEditor.new(**opts).call
  end

  test "renders the query-editor controller shell with highlight + input targets" do
    html = render_editor(value: "@message like /INVITE/")

    assert_includes html, 'data-controller="query-editor"'
    assert_includes html, 'data-query-editor-target="highlight"'
    assert_includes html, 'data-query-editor-target="input"'
    assert_includes html, "@message like /INVITE/", "the value pre-fills the textarea so highlight paints on connect"
  end

  test "the form field name renders only when given" do
    assert_includes render_editor(name: "q"), 'name="q"'
    assert_not_includes render_editor, 'name="q"'
  end

  test "submits:false emits the off flag; default (true) omits it" do
    assert_includes render_editor(submits: false), 'data-query-editor-submits-value="false"'
    assert_not_includes render_editor, "submits-value"
  end

  test "input_data is merged onto the textarea so a host controller can claim it" do
    html = render_editor(input_data: {dashboard_builder_target: "logQuery"})

    assert_includes html, 'data-dashboard-builder-target="logQuery"'
  end

  test "help_limit:false drops the limit cheatsheet line (a count tallies all matches)" do
    assert_includes render_editor(help_limit: true), "limit 1000"
    assert_not_includes render_editor(help_limit: false), "limit 1000"
  end

  test "show_help:false hides the cheatsheet entirely" do
    assert_includes render_editor(show_help: true), "Syntax"
    assert_not_includes render_editor(show_help: false), "Syntax"
  end

  test "label renders only when given" do
    assert_includes render_editor(label: "Query"), "Query"
    assert_not_includes render_editor, "Query"
  end
end
