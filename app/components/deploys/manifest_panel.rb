# frozen_string_literal: true

# What the box read out of one repository: its `.voodu/**/*.yml`, the verdict
# on each, and whether anything on the box authorises them to run.
#
# FOUR STATES, FOUR DIFFERENT SENTENCES, and that is the design rather than
# tidiness. Each has a different fix:
#
#   the box did not answer     → a network or a token. NOT "no config".
#   no `.voodu/*.yml` at all   → write a file, and here is one.
#   a file did not parse       → that file's error, the others still listed.
#   no trigger on the box      → one command, on the box, shown.
#
# Collapsing the first into the third is the failure worth naming: telling
# somebody there is no configuration when we could not ask sends them looking
# for a file that never moved.
class Components::Deploys::ManifestPanel < Components::Base
  def initialize(data:)
    @data = data
    @repo = data.selected
    @manifests = data.manifests
  end

  def view_template
    div(class: "flex flex-col gap-3") do
      repo_head

      if @manifests.unsupported?
        unsupported
      elsif @manifests.unreachable?
        unreachable
      else
        trigger_state
        preflight
        stats_strip
        refused_summary
        @manifests.any? ? file_browser : no_files
      end
    end
  end

  private

  # repo_head, not `header` — that is a Phlex HTML tag method.
  def repo_head
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2") do
      div(class: "flex flex-col min-w-0 basis-full vmd:basis-auto vmd:flex-1") do
        span(class: "text-[14px] font-semibold text-voodu-text font-voodu-mono truncate") do
          @repo.full_name
        end
        span(class: "text-[11.5px] text-voodu-muted truncate") { ref_line }
      end

      div(class: "flex items-center gap-2 shrink-0") do
        render Components::UI::Button.new(
          tag: :a, href: @repo.html_url, target: "_blank", rel: "noopener",
          variant: :ghost, size: :sm
        ) do
          render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3.5 h-3.5")
          span(class: "hidden vmd:inline") { "GitHub" }
        end
      end
    end
  end

  def ref_line
    parts = [@manifests.ref.presence || @repo.default_branch]
    parts << @manifests.commit.to_s[0, 7] if @manifests.commit.present?

    parts.compact_blank.join(" · ")
  end

  # A 404 is not an outage, and it is not a missing repository. This controller
  # simply predates the deploy plane, and the fix is a version rather than a
  # network — saying "could not read this repository" here sends the operator
  # to look at GitHub, or at their firewall, for something neither one did.
  def unsupported
    render Components::UI::Callout.new(
      tone: :info, title: "#{@data.server.name} is running a controller without the deploy plane"
    ) do
      span(class: "text-[12.5px] text-voodu-text-2") do
        plain "Deploying from a repository needs a controller that exposes the deploy routes over "
        plain "the PAT plane. Upgrade #{@data.server.name} and this panel fills itself in."
      end
      span(class: "text-[12px] text-voodu-muted") do
        plain "Nothing is wrong with #{@repo.full_name} or with your GitHub connection."
      end
    end
  end

  # An unreachable box is not an empty configuration. See the class comment.
  def unreachable
    render Components::UI::Callout.new(tone: :warning, title: "Could not read this repository") do
      span(class: "text-[12.5px] text-voodu-text-2") { @manifests.error.to_s }
      span(class: "text-[12px] text-voodu-muted") do
        plain "Nothing changed on the repository or on the box — this page just cannot ask right now."
      end
    end
  end

  # Whether the BOX authorises this repository, which is a different question
  # from whether the YAML is valid. A perfect file with no trigger deploys
  # nothing, and that is the state most likely to be mistaken for a bug.
  def trigger_state
    unless @data.box_reachable?
      return warn_row("#{@data.server.name} did not answer, so we cannot say what it authorises.")
    end

    trigger = @data.trigger_for(@repo.full_name)

    return trigger_row(trigger) if trigger

    connect_form
  end

  # connect_form — the one write in VooduCD, and the screen says what it does.
  #
  # It creates the trigger ON THE BOX and records the repository here, in one
  # click. That the console may widen what a box accepts is a deliberate trade
  # — the alternative is every developer holding SSH to production so one of
  # them can run the CLI. The box records every trigger change in its activity
  # trail, which is the half that makes it a trade rather than a loss, and the
  # form says so out loud instead of leaving it in a design document.
  def connect_form
    render Components::UI::Callout.new(tone: :warning, title: "Not deploying here yet") do
      span(class: "text-[12px] text-voodu-text-2") do
        plain "The files below are read, but nothing on #{@data.server.name} authorises them to run."
      end

      form(action: connect_repo_deploys_path, method: "post", class: "flex flex-col gap-2.5") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        input(type: "hidden", name: "repo", value: @repo.full_name)

        div(class: "flex flex-col vmd:flex-row vmd:items-end gap-2.5") do
          branch_field
          scopes_field

          render Components::UI::Button.new(
            tag: :button, type: :submit, variant: :primary, size: :sm, class: "h-9 shrink-0"
          ) do
            render Icon::RocketLaunchOutline.new(class: "w-3.5 h-3.5")
            span { "Deploy here" }
          end
        end
      end

      span(class: "text-[11.5px] text-voodu-muted") do
        plain "This creates a trigger on #{@data.server.name}. It appears in that server's "
        plain "activity trail, and you can remove it from here or with `vd deploy trigger delete`."
      end
    end
  end

  # The branch is a GUARANTEE, not a selection: every commit this trigger
  # deploys must descend from it. Which pushes actually fire is decided by
  # `on.push.branches` in the YAML — a different question, in a different
  # place, and conflating them is how somebody grants more than they meant.
  def branch_field
    div(class: "flex flex-col gap-1.5 basis-full vmd:basis-48 min-w-0") do
      field_label("Branch", "Deployed commits must descend")

      input(
        type: "text", name: "branch", value: @repo.default_branch, required: true,
        autocomplete: "off", spellcheck: "false", class: field_class
      )
    end
  end

  # Required, and the box requires it too: a trigger that allows nothing can
  # deploy nothing, so an empty list is a mistake rather than a policy. The
  # datalist SUGGESTS what already runs here without closing the list — a scope
  # with nothing running yet is exactly the first-deploy case.
  def scopes_field
    div(class: "flex flex-col gap-1.5 basis-full vmd:flex-1 min-w-0") do
      field_label("Scopes it may apply", "Comma separated. The box refuses anything else")

      input(
        type: "text", name: "allow_scopes", required: true, list: "deploy-scopes",
        placeholder: "prod, staging", autocomplete: "off", spellcheck: "false",
        class: field_class
      )

      datalist(id: "deploy-scopes") do
        @data.known_scopes.each { |scope| option(value: scope) }
      end
    end
  end

  def field_label(text, hint)
    div(class: "flex flex-col gap-0.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { text }
      span(class: "text-[10.5px] text-voodu-muted") { hint }
    end
  end

  def field_class
    "w-full px-3 h-9 bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
      "font-voodu-mono text-[12.5px] outline-none placeholder:text-voodu-muted-2 " \
      "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line"
  end

  def trigger_row(trigger)
    enabled = trigger["enabled"] != false

    div(class: "flex flex-wrap items-center gap-2 border border-voodu-border bg-voodu-surface px-3.5 py-2.5") do
      render Components::UI::Badge.new(variant: enabled ? :success : :neutral) do
        enabled ? "Trigger enabled" : "Trigger paused"
      end

      span(class: "text-[12px] text-voodu-muted") { "descends from" }
      span(class: "font-voodu-mono text-[12px] text-voodu-text-2") { trigger["branch"].to_s }

      if Array(trigger["allow_scopes"]).any?
        span(class: "text-[12px] text-voodu-muted") { "· may apply" }
        span(class: "font-voodu-mono text-[12px] text-voodu-text-2 truncate") do
          Array(trigger["allow_scopes"]).join(", ")
        end
      end

      div(class: "hidden vmd:block flex-1")
      disconnect_form
    end
  end

  # Removing the listing here AND the trigger on the box. Confirmed, because
  # the second half is not undoable from this screen — recreating it is a new
  # trigger with a new id, and anything that recorded the old one is stale.
  def disconnect_form
    form(action: disconnect_repo_deploys_path, method: "post", class: "shrink-0") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "repo", value: @repo.full_name)

      render Components::UI::Button.new(
        tag: :button, type: :submit, variant: :ghost, size: :sm,
        data: {turbo_confirm: "Stop deploying #{@repo.full_name} to #{@data.server.name}? " \
                              "Its trigger is removed from the server too."}
      ) do
        render Icon::XMarkOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "Disconnect" }
      end
    end
  end

  # Asked for, not automatic: see Components::Deploys::PreflightPanel.
  #
  # AND ONLY ONCE A TRIGGER EXISTS. The box's preflight endpoint takes a
  # trigger id — the four questions are about an AUTHORISATION, so there is
  # nothing to ask before one exists. Offering the button beside "Not deploying
  # here yet" put two contradictory things on screen and made the operator
  # click one to be told to use the other.
  def preflight
    return unless @data.box_reachable?
    return if @data.trigger_for(@repo.full_name).nil?

    render Components::Deploys::PreflightPanel.new(data: @data)
  end

  # The numbers come free with the listing the box already fetched to find the
  # YAML — zero extra requests. They measure the WORKING TREE, not the
  # repository: GitHub's `size` counts git objects with history, which is
  # neither what a deploy downloads nor what a build reads.
  def stats_strip
    stats = @manifests.stats

    return if stats.nil? || stats.files.to_i.zero?

    div(class: "flex flex-wrap items-center gap-x-3 gap-y-1 text-[11.5px] text-voodu-muted") do
      stat_item(stats.files.to_s, "files")
      stat_item(stats.human_bytes, "working tree")

      stats.top_languages(4).each do |lang|
        span(class: "font-voodu-mono text-voodu-text-2") { lang["ext"].to_s }
      end

      truncated_note if @manifests.truncated
    end
  end

  def stat_item(value, label)
    span do
      span(class: "font-voodu-mono text-voodu-text-2") { value }
      plain " #{label}"
    end
  end

  # A partial sum presented as a total is a number that looks precise and is
  # wrong. Said out loud rather than left for somebody to discover.
  def truncated_note
    span(class: "text-voodu-amber", title: "The repository was too large for one tree listing") do
      "counts are partial"
    end
  end

  # refused_summary — the broken files, named, WITHOUT having to click them.
  #
  # The viewer opens on a file the box could use, which is right — but it means
  # a refused file is otherwise a small icon in a sidebar. An operator who came
  # to find out why nothing deploys should not have to click each file to
  # discover one of them never parsed.
  def refused_summary
    refused = @manifests.invalid_files

    return if refused.empty?

    render Components::UI::Callout.new(
      tone: :danger, title: "#{refused.size} #{"file".pluralize(refused.size)} refused"
    ) do
      refused.each do |file|
        div(class: "flex flex-col vmd:flex-row vmd:gap-2 min-w-0") do
          a(href: file_href(file),
            class: "font-voodu-mono text-[11.5px] text-voodu-text-2 underline shrink-0") { file.path }
          span(class: "text-[11.5px] text-voodu-text-2 min-w-0 break-words") { file.error.to_s }
        end
      end
    end
  end

  # Sidebar of files beside the viewer on desktop; stacked on mobile, where a
  # two-column split of a YAML file is a column of single characters.
  def file_browser
    div(class: "flex flex-col vmd:flex-row gap-3 items-stretch") do
      file_list
      viewer
    end
  end

  def file_list
    nav(class: "flex flex-col gap-1 vmd:w-56 shrink-0") do
      @manifests.files.each { |file| file_link(file) }
    end
  end

  def file_link(file)
    current = @data.selected_file&.path == file.path

    a(href: file_href(file), class: file_link_class(current)) do
      div(class: "flex items-center gap-1.5 min-w-0") do
        if file.valid?
          render Icon::DocumentTextOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
        else
          render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-red")
        end

        span(class: "text-[12.5px] truncate") { file.display_name }
      end

      span(class: "font-voodu-mono text-[10.5px] text-voodu-muted-2 truncate") { file.path }
    end
  end

  def file_link_class(current)
    base = "flex flex-col gap-0.5 px-2.5 py-2 border no-underline transition-colors "

    base + if current
      "border-voodu-accent-line bg-voodu-accent-dim text-voodu-text"
    else
      "border-voodu-border bg-voodu-surface text-voodu-text-2 hover:border-voodu-border-2"
    end
  end

  def file_href(file)
    deploys_repositories_path(repo: @repo.full_name, file: file.path)
  end

  def viewer
    file = @data.selected_file

    div(class: "flex-1 min-w-0 border border-voodu-border bg-voodu-surface-2 flex flex-col") do
      viewer_head(file)

      if file.valid?
        render Components::Deploys::YamlBlock.new(text: file.to_yaml_text, path: file.path)
      else
        invalid_body(file)
      end
    end
  end

  # Says where the YAML came from, because it is NOT the bytes in the
  # repository — it is what the box understood after parsing. That distinction
  # is the whole value of the panel when a file is not doing what somebody
  # expected, and hiding it would make the page look like a file viewer.
  def viewer_head(file)
    div(class: "flex flex-wrap items-center gap-2 px-3 py-2 border-b border-voodu-border") do
      span(class: "font-voodu-mono text-[11.5px] text-voodu-text-2 truncate flex-1 min-w-0") { file.path }

      if file.valid?
        render Components::UI::Badge.new(variant: :success) { "as the box read it" }
      else
        render Components::UI::Badge.new(variant: :danger) { "refused" }
      end
    end
  end

  def invalid_body(file)
    div(class: "p-3 flex flex-col gap-2") do
      span(class: "text-[12.5px] text-voodu-red") { file.error.to_s }
      span(class: "text-[12px] text-voodu-muted") do
        plain "The other files in this repository are unaffected — only this one is skipped."
      end
    end
  end

  # An empty `.voodu/` is the NORMAL state on the day somebody connects a
  # repository, and it is this screen's only teaching moment: the reader has
  # one question — what do I write? — and the answer is four lines they will
  # never guess. See Components::Deploys::TriggerExamples.
  def no_files
    div(class: "border border-voodu-border bg-voodu-surface px-3.5 py-3.5") do
      render Components::Deploys::TriggerExamples.new(
        repo: @repo.full_name, branch: @repo.default_branch
      )
    end
  end

  def warn_row(message)
    render Components::UI::Callout.new(tone: :warning) do
      span(class: "text-[12.5px] text-voodu-text-2") { message }
    end
  end
end
