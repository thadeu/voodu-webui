# frozen_string_literal: true

# The deployment history as a table.
#
# Columns chosen by what an operator scans FOR: the SHA identifies, the message
# is what they recognise ("the redis fix"), and the status is the answer. The
# rest is context and hides below the breakpoint.
class Components::Deploys::DeploymentTable < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    return empty_state if @data.rows.empty?

    div(class: "border border-voodu-border bg-voodu-surface flex flex-col") do
      column_head
      @data.rows.each { |deployment| row(deployment) }
    end
  end

  private

  # Hidden below the breakpoint: a header row over stacked cards labels
  # nothing, and takes a line doing it.
  def column_head
    div(class: "hidden vmd:flex items-center gap-3 px-3 h-8 border-b border-voodu-border " \
               "bg-voodu-surface-2 text-[10.5px] uppercase tracking-wider text-voodu-muted") do
      div(class: "w-5 shrink-0")
      span(class: "w-20 shrink-0") { "Commit" }
      span(class: "flex-1 min-w-0") { "Message" }
      span(class: "w-40 shrink-0") { "Repository" }
      span(class: "w-16 shrink-0 text-right") { "Took" }
      span(class: "w-24 shrink-0") { "Status" }
      span(class: "w-24 shrink-0 text-right") { "When" }

      div(class: "w-7 shrink-0")
    end
  end

  # One row, its own component: the deliveries screen lists the deployments a
  # delivery produced, and two copies of a row are two rows that drift.
  def row(deployment)
    render Components::Deploys::DeploymentRow.new(deployment: deployment)
  end

  # Nothing has ever deployed here and a filter matching nothing are different
  # states with different next steps.
  def empty_state
    div(class: "border border-voodu-border bg-voodu-surface px-3.5 py-8 flex flex-col gap-2 text-center") do
      if @data.filtered?
        p(class: "m-0 text-[12.5px] text-voodu-muted") { "No deployment matches those filters." }
      else
        p(class: "m-0 text-[12.5px] text-voodu-text-2") { "Nothing has deployed to this server yet." }
        p(class: "m-0 text-[12px] text-voodu-muted") do
          plain "Connect a repository and push — deploys show up here as they happen."
        end
        a(href: deploys_repositories_path, class: "text-[12px] text-voodu-link underline") do
          "Connected repositories"
        end
      end
    end
  end
end
