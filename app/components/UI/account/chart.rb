class UI::Account::Chart < ApplicationComponent
  attr_reader :account

  def initialize(account:, period: nil, view: nil, period_selected_param: nil, period_start_param: nil, period_end_param: nil, period_error: nil)
    @account = account
    @period = period
    @view = view
    @period_selected_param = period_selected_param
    @period_start_param = period_start_param
    @period_end_param = period_end_param
    @period_error = period_error
  end

  def period
    @period ||= Period.last_30_days
  end

  def holdings_value_money
    account.balance_money - account.cash_balance_money
  end

  def view_balance_money
    case view
    when "balance"
      account.balance_money
    when "holdings_balance"
      holdings_value_money
    when "cash_balance"
      account.cash_balance_money
    end
  end

  def title
    case account.accountable_type
    when "Investment", "Crypto"
      case view
      when "balance"
        "Total account value"
      when "holdings_balance"
        "Holdings value"
      when "cash_balance"
        "Cash value"
      end
    when "Property", "Vehicle"
      "Estimated #{account.accountable_type.humanize.downcase} value"
    when "CreditCard", "OtherLiability"
      "Debt balance"
    when "Loan"
      "Remaining principal balance"
    else
      "Balance"
    end
  end

  def foreign_currency?
    account.currency != account.family.currency
  end

  def converted_balance_money
    return nil unless foreign_currency?

    account.balance_money.exchange_to(account.family.currency, fallback_rate: 1)
  end

  def view
    @view ||= "balance"
  end

  def series
    account.balance_series(period: period, view: view)
  end

  def trend
    series.trend
  end

  # Helpers used by the template to control the custom date UI
  def selected_key
    (@period_selected_param == "custom") ? "custom" : (period.key || "custom")
  end

  def period_start_value
    @period_start_param.presence || period.start_date
  end

  def period_end_value
    @period_end_param.presence || period.end_date
  end

  def period_error
    @period_error
  end
end
