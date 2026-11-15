# GET /exchange_rate?from=USD&to=UAH&date=2026-11-01
#
# The one rate lookup the forms use to prefill a conversion (the transaction and transfer
# exchange-rate tabs, the subscription amount hint). It follows the nearest-rate rule
# (ExchangeRate.find_rate): the day's rate, else the latest stored one before it, else the
# earliest after it. The response names the date of the rate it found, so a form can say
# how old it is. With no rate at all it answers 404 and never 1.
class ExchangeRatesController < ApplicationController
  def show
    from = currency_param(:from)
    to = currency_param(:to)
    return render json: { error: "invalid_currency" }, status: :bad_request unless from && to

    date = date_param
    return render json: { error: "invalid_date" }, status: :bad_request unless date

    return render json: { from: from, to: to, rate: 1.0, same_currency: true } if from == to

    rate = ExchangeRate.find_rate(from: from, to: to, date: date)

    if rate && ExchangeRate.valid_rate?(rate.rate)
      render json: { from: from, to: to, rate: rate.rate.to_f, date: rate.date.iso8601, requested_date: date.iso8601 }
    else
      render json: { error: "rate_unavailable", from: from, to: to }, status: :not_found
    end
  end

  private
    def currency_param(key)
      value = params[key].to_s.strip.upcase
      return if value.blank?

      Money::Currency.new(value).iso_code
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    # Blank is today. A date after today asks for today's rate: no rate is published ahead.
    def date_param
      return Date.current if params[:date].blank?

      [ Date.iso8601(params[:date].to_s), Date.current ].min
    rescue ArgumentError
      nil
    end
end
