# frozen_string_literal: true

# The onboarding for a repository with no `.voodu/` yet.
#
# THIS IS THE SCREEN'S ONLY TEACHING MOMENT. An operator who has just connected
# a repository and sees "no trigger file" has one question — what do I write? —
# and the answer is four lines of YAML they will never guess. Sending them to
# documentation here is sending them away at the moment they were ready to act.
#
# The examples are TAILORED to the repository in front of them: their default
# branch, not `main`; their name in the comment. A generic snippet makes the
# reader translate before they can paste, and translation is where the branch
# quietly stays wrong.
#
# One recommended shape shown open, the variations folded. Three YAML blocks
# stacked is a wall; one plus "there are other shapes" is a starting point.
class Components::Deploys::TriggerExamples < Components::Base
  def initialize(repo:, branch:, dir: DeploysData::TRIGGER_DIR)
    @repo = repo
    @branch = branch.presence || "main"
    @dir = dir
  end

  def view_template
    div(class: "flex flex-col gap-3") do
      heading
      primary
      variations
      next_step
    end
  end

  private

  # INFO, not a warning: an empty `.voodu/` on the day somebody connects a
  # repository is the expected state, not a problem they caused. Amber here
  # would tell them something is wrong when nothing is.
  def heading
    render Components::UI::Callout.new(
      tone: :info, title: "Add a trigger file to start deploying"
    ) do
      span(class: "text-[12.5px] text-voodu-text-2") do
        plain "#{@repo} has no #{@dir}/ yet. Commit one of these on "
        span(class: "font-voodu-mono") { @branch }
        plain " and it appears here."
      end
    end
  end

  def primary
    example(
      title: "The simplest one",
      hint: "Deploys every push to #{@branch}.",
      yaml: <<~YAML
        # #{@dir}/deploy.yml
        name: #{suggested_name}
        on:
          push:
            branches: [#{@branch}]
        apply:
          file: voodu.hcl
      YAML
    )
  end

  # `<details>` and not tabs: it needs no JavaScript, it is readable with the
  # bundle unloaded, and a reader who wants the simple case never opens it.
  def variations
    details(class: "border border-voodu-border bg-voodu-surface") do
      summary(class: "px-3 py-2 text-[12px] text-voodu-text-2 cursor-pointer select-none") do
        "Other shapes"
      end

      div(class: "px-3 pb-3 flex flex-col gap-3") do
        example(
          title: "Only when certain paths change",
          hint: "A README commit does not restart production. Paths are glob patterns.",
          yaml: <<~YAML
            # #{@dir}/api.yml
            name: API
            on:
              push:
                branches: [#{@branch}]
                paths:
                  - "app/**"
                  - "config/**"
                  - "voodu.hcl"
            apply:
              file: voodu.hcl
          YAML
        )

        example(
          title: "Push freely, deploy by hand",
          hint: "Every push is recorded but nothing applies until you press play on the " \
                "commit you want — push-1, test it, then push-2. Like workflow_dispatch, " \
                "without a runner.",
          yaml: <<~YAML
            # #{@dir}/api.yml
            name: API
            on:
              push:
                branches: [#{@branch}]
            deploy: manual
            apply:
              file: voodu.hcl
          YAML
        )

        example(
          title: "Two files, two workloads",
          hint: "Every #{@dir}/**/*.yml is read. Split them when parts of the " \
                "repository deploy on different pushes.",
          yaml: <<~YAML
            # #{@dir}/worker.yml
            name: Worker
            on:
              push:
                branches: [#{@branch}]
                paths: ["app/jobs/**"]
            apply:
              file: voodu.hcl
          YAML
        )
      end
    end
  end

  def example(title:, hint:, yaml:)
    div(class: "flex flex-col gap-1.5") do
      div(class: "flex flex-col gap-0.5") do
        span(class: "text-[12px] font-medium text-voodu-text-2") { title }
        span(class: "text-[11.5px] text-voodu-muted") { hint }
      end

      div(class: "bg-voodu-surface-2 border border-voodu-border") do
        render Components::Deploys::YamlBlock.new(text: yaml, copy_label: "Copy this example")
      end
    end
  end

  # What happens AFTER they commit, because the file alone deploys nothing —
  # and discovering that by pushing and watching nothing happen is the worst
  # possible way to learn it.
  # NEUTRAL, deliberately quieter than the heading above it. Two blue rules
  # stacked would give equal weight to "here is what to write" and "and by the
  # way", when only the first is why the reader is here.
  def next_step
    render Components::UI::Callout.new(tone: :neutral) do
      span(class: "text-[11.5px] text-voodu-text-2") do
        plain "Committing the file is half of it. This repository also has to be "
        plain "connected to this server above — that is what authorises the box to act on a push."
      end
    end
  end

  # A name the operator would have picked, from the repository. `apply.file`
  # stays `voodu.hcl` because that is the convention, and guessing a manifest
  # this component has not seen would be worse than a name they will correct.
  def suggested_name
    @repo.to_s.split("/").last.to_s.split(/[-_]/).map(&:capitalize).join(" ").presence || "App"
  end
end
