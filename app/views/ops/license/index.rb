# frozen_string_literal: true

# License — installation-wide, and named for what it is.
#
# Split out of a single "Installation" screen, which described the SCOPE rather
# than the subject: both live at the container level, but one is what you bought
# and the other is how people get in. Nobody looking for either searches for
# "installation".
class Views::Ops::License::Index < Views::Base
  def initialize(current_path:, servers: [])
    @current_path = current_path
    @servers = servers
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, breadcrumb: [{label: "License"}]
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        page_header
        columns
      end
    end
  end

  private

  # Two columns above 1280px: what this installation HAS, beside what it could
  # have. One column below that, because a 340px pitch squeezed next to a table
  # of limits is unreadable — and on a phone the plan is what someone came for,
  # so it stays first in the source and therefore first on the page.
  #
  # max-w-5xl rather than the old max-w-3xl: the card kept its width and the
  # pitch was given the room that was empty anyway.
  def columns
    div(class: "grid grid-cols-1 vlg:grid-cols-[minmax(0,1fr)_minmax(0,340px)] " \
               "items-start gap-4 vmd:gap-5 max-w-5xl") do
      plan_card
      upgrade_cta
    end
  end

  # Nothing to sell to someone who already bought. An installation inside its
  # grace period is still entitled, and being advertised at while holding a
  # licence that merely needs renewing would read as the product not knowing
  # what it had sold — the expiry on the left already says what to do.
  def upgrade_cta
    return if license.entitled?

    render Components::UI::UpsellCard.new(
      title: "Enterprise",
      headline: "Run it without the limits",
      blurb: "The free tier is meant for one operator on one box. Enterprise lifts " \
             "the caps and lets the control plane live in your own Postgres.",
      features: [
        "Unlimited orgs and member invites",
        "90 days of searchable history, up from 3",
        "Postgres for the control plane — bring your own database",
        "Single sign-on, so people arrive as themselves"
      ],
      primary: {label: "See Enterprise", href: "https://voodu.clowk.in/license/enterprise"},
      secondary: {label: "Email us", href: "mailto:hello@clowk.in?subject=Voodu%20Enterprise"},
      footnote: "Paste the licence into the form on the left — it takes effect immediately, no restart."
    )
  end

  def page_header
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "License" }
      p(class: "text-[12.5px] text-voodu-muted") { plain "What this installation is licensed for, and how to activate or renew it." }
    end
  end

  # ── Plan ───────────────────────────────────────────────────────────

  # Its own card rather than a row in About, because it is the only place an
  # operator can act on their licence: see what they have, and paste a new one.
  # Renewal without a restart is the point — the alternative is editing an env
  # var and bouncing the dashboard someone is watching.
  def plan_card
    # On the hosted service the box is not the customer's, so its licence is
    # not shown to them at all — same rule that removed the SSO screen and the
    # topbar badge. It was actively misleading here: the row read
    # "Unlimited · voodu-hosted-dev", naming OUR entitlement and OUR customer
    # id, directly above a Limits row reading "0 invites" that came from THEIR
    # plan. Two subjects in one card, contradicting each other.
    return account_plan_card if license.unlimited?

    render Components::UI::SectionCard.new(title: "Plan") do
      div do
        render(Components::UI::KvRow.new(key: "Plan")) { plan_value }
        render(Components::UI::KvRow.new(key: "Expires")) { plan_expiry_value } if license.present?
        render(Components::UI::KvRow.new(key: "Limits")) { plan_limits_value }
        render(Components::UI::KvRow.new(key: "Database")) { database_value }
      end

      license_history if allowed_anywhere?(:manage_account)

      activation_form if allowed_anywhere?(:manage_account)
    end
  end

  def account_plan_card
    # plan_account, NOT current_org&.account and not current_account either.
    #
    # This route takes no :org_id by design, so the org is nil here on every
    # visit and the card returned early every time — taking plan_form with it,
    # which is the only way to upgrade. And where an org WAS in scope, an
    # invited admin would have been shown the plan of the company that invited
    # them, under a heading saying it was theirs.
    account = plan_account
    return if account.nil?

    render Components::UI::SectionCard.new(title: "Your plan · #{account.name}") do
      div do
        render(Components::UI::KvRow.new(key: "Plan")) do
          span(class: "font-voodu-mono text-[12px] text-voodu-text") { account.plan.capitalize }
        end
        render(Components::UI::KvRow.new(key: "Limits")) { plan_limits_value }
        plan_expiry_row(account)
      end

      plan_form(account) if account.owner_id == current_user&.id
      hosted_footnote
    end
  end

  # Says who to ask about everything NOT on this card. Without it the screen
  # reads as though the plan above is all there is to a licence, and a customer
  # wondering about the installation has nowhere to look.
  def hosted_footnote
    p(class: "m-0 p-3.5 border-t border-voodu-border text-[12px] text-voodu-muted leading-relaxed") do
      plain "This is the plan on the account you own. Orgs you were invited into are "
      plain "governed by their own owner's plan, not by this one — and this dashboard "
      plain "runs as a hosted service, so the installation itself is managed by whoever "
      plain "operates it."
    end
  end

  # Every licence this installation has run under.
  #
  # The rows were always being written — one per activation — and nothing showed
  # them. What they answer is the question support actually gets asked: when did
  # this installation become Enterprise, under whose name, and who pasted it.
  # Owner-only, same bracket as the form, because it names people.
  # Extracted rather than inline: it is a filtered table, and the house already
  # has a shape for those (Components::Orgs::MembersTable).
  def license_history
    keys = Ops::License.newest_first.to_a
    return if keys.empty?

    div(class: "flex flex-col gap-1.5 p-3.5 border-t border-voodu-border") do
      span(class: "text-[11px] uppercase tracking-wide text-voodu-muted") { "License history" }
      render Components::Licenses::HistoryTable.new(keys: keys)
    end
  end

  # Only ever Enterprise now: plan_card returns early on the hosted tier, so
  # this never renders for an unlimited licence. Kept as a named method rather
  # than inlined because plan_value reads better with it, and spelled without
  # the dead branch so nobody trusts a ternary that cannot take its other arm.
  def plan_name = "Enterprise"

  # Only when there IS one — a free account has no licence and no date, and an
  # empty row would look like something failed to load.
  def plan_expiry_row(account)
    expires = account.plan_license.expires_at
    return if expires.nil?

    render(Components::UI::KvRow.new(key: "Renews")) do
      span(class: "font-voodu-mono text-[12px] text-voodu-text-2") { expires.to_date.to_s }
    end
  end

  # The customer's own licence, which is a different token from the box's and
  # goes in a different place. Same shape as the installation form so nobody
  # has to learn two, and the copy says whose it is.
  def plan_form(account)
    form(action: ops_license_path, method: "post",
      class: "flex flex-col gap-2 p-3.5 border-t border-voodu-border") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "scope", value: "plan")
      input(type: "hidden", name: "return_to", value: @current_path)

      label(class: "text-[12px] text-voodu-muted", for: "plan-token") do
        plain account.pro? ? "Replace your plan licence" : "Activate a plan licence"
      end

      textarea(
        id: "plan-token", name: "license_token", rows: "3",
        placeholder: "eyJhbGciOiJSUzI1NiJ9…",
        class: "w-full font-voodu-mono text-[11.5px] break-all px-2.5 py-2 " \
               "bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
               "focus:outline-none focus:border-voodu-accent"
      )

      div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2") do
        render Components::UI::Button.new(tag: :button, type: "submit", variant: :primary, size: :sm) do
          "Activate"
        end
        span(class: "text-[11.5px] text-voodu-muted") do
          plain "Issued for this account (#{account.short_id}) — a licence for another will be refused."
        end
      end
    end
  end

  def plan_limits_value
    e = entitlements

    span(class: "font-voodu-mono text-[12px] text-voodu-text-2") do
      plain "#{plan_count(e.limit(:orgs))} orgs · "
      plain "#{plan_count(e.limit(:member_invites))} invites · "
      plain "#{e.retention_days}d searchable"
      plain " · Postgres" if e.postgres?
    end
  end

  def plan_count(value) = value.nil? ? "∞" : value.to_s

  # The licence grants the OPTION of Postgres; DATABASE_URL is how an operator
  # takes it. Both facts belong here, because "am I on Postgres" and "may I be"
  # are different questions and only one of them is about the plan.
  def database_value
    postgres = primary_adapter.start_with?("postgres")

    span(class: "font-voodu-mono text-[12px]") do
      span(class: "text-voodu-text") { postgres ? "Postgres" : "SQLite" }
      span(class: "text-voodu-muted") { " · control plane" }
      span(class: "text-voodu-muted") { " · warehouse always SQLite" }
    end
  end

  def activation_form
    form(action: ops_license_path, method: "post", class: "flex flex-col gap-2 p-3.5 border-t border-voodu-border") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "return_to", value: @current_path)

      label(class: "text-[12px] text-voodu-muted", for: "license-token") do
        plain license.present? ? "Replace the licence" : "Activate a licence"
      end

      textarea(
        id: "license-token", name: "license_token", rows: "3",
        placeholder: "eyJhbGciOiJSUzI1NiJ9…",
        class: "w-full font-voodu-mono text-[11.5px] break-all px-2.5 py-2 " \
               "bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
               "focus:outline-none focus:border-voodu-accent"
      )

      div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2") do
        render Components::UI::Button.new(type: "submit", variant: :primary, size: :sm) { "Activate" }
        span(class: "text-[11.5px] text-voodu-muted") do
          plain "Takes effect immediately — no restart."
        end
      end
    end
  end

  # ── Plan values ────────────────────────────────────────────────────

  def license = LicenseToken.current

  # Shown even on the free tier, and deliberately: an operator who cannot see
  # which plan they are on files a ticket to ask. A lapsed or unverifiable
  # licence has to be loud here — it is the only place that explains why a
  # capability they paid for stopped applying.
  def plan_value
    case license.status
    when :none
      span(class: "text-voodu-text-2") { "Free" }
    when :valid
      span(class: "text-voodu-text") { "#{plan_name} · #{license.customer}" }
    when :grace
      span(class: "text-voodu-amber") { "#{plan_name} · #{license.customer} — expired, in grace" }
    when :lapsed
      span(class: "text-voodu-red") { "Free — licence for #{license.customer} lapsed" }
    when :invalid
      span(class: "text-voodu-red") { "Free — licence could not be verified" }
    end
  end

  def plan_expiry_value
    expires = license.expires_at
    return span(class: "text-voodu-muted") { "—" } if expires.nil?

    days = license.days_until_expiry
    tone = if days.negative? then "text-voodu-red"
    elsif days <= 30 then "text-voodu-amber"
    else "text-voodu-text-2"
    end

    span(class: "font-voodu-mono #{tone}") do
      plain expires.to_date.to_s
      plain days.negative? ? " (#{days.abs}d ago)" : " (in #{days}d)"
    end
  end
end
