# frozen_string_literal: true

# The charges of the account's subscription, newest first — beside the plan
# they paid for, so "was I charged this month, and how much" is answered on
# the screen where the customer manages the subscription.
#
# Same shape as Components::Licenses::HistoryTable without its filter: one
# row a month is a short list for years, and the newest rows are the ones
# anybody comes for.
class Components::Payments::HistoryTable < Components::Base
  # Two years of monthly charges. Older ones are in the broker's dashboard.
  LIMIT = 24

  def initialize(payments:)
    @payments = payments
  end

  def view_template
    div(class: "border border-voodu-border bg-voodu-surface") do
      @payments.each { |payment| payment_row(payment) }
    end
  end

  private

  # Stacks on narrow and goes to a row at the breakpoint, like the license
  # history: date, what it was for, how much, what happened to it.
  def payment_row(payment)
    div(class: "flex flex-col vmd:flex-row vmd:items-baseline gap-0.5 vmd:gap-4 px-3.5 py-2.5 " \
               "border-b border-voodu-border-2 last:border-b-0") do
      span(class: "text-[12px] font-voodu-mono text-voodu-text-2 vmd:w-24 shrink-0") do
        (payment.paid_at || payment.created_at).to_date.to_s
      end

      span(class: "text-[11.5px] text-voodu-muted vmd:flex-1 min-w-0 truncate") do
        payment.description.presence || "Voodu Pro"
      end

      span(class: "text-[12px] font-voodu-mono text-voodu-text vmd:w-28 vmd:text-right shrink-0") do
        money(payment.currency, payment.amount)
      end

      span(class: "text-[11.5px] font-voodu-mono vmd:w-36 vmd:text-right shrink-0 #{tone(payment)}") do
        status_text(payment)
      end
    end
  end

  def status_text(payment)
    return "refunded #{money(payment.currency, payment.refunded_amount)}" if payment.partially_refunded?

    {"paid" => "paid", "failed" => "declined", "refunded" => "refunded"}.fetch(payment.status, payment.status)
  end

  # Kernel's sprintf by name: inside a component `format` is not it.
  def money(currency, amount) = "#{currency} #{Kernel.format("%.2f", amount)}"

  def tone(payment)
    case payment.status
    when "paid" then "text-voodu-text-2"
    when "failed" then "text-voodu-red"
    else "text-voodu-amber"
    end
  end
end
