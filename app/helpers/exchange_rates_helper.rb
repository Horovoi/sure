module ExchangeRatesHelper
  # The data attributes that wire a form to exchange_rate_form_controller.js: the rate
  # lookup URL, each account's currency and the texts it fills in. mode is "transfer"
  # (the two accounts' currencies) or "transaction" (the amount's currency and the
  # account's). Merge the result into the form's data.
  def exchange_rate_form_data(mode:, accounts:)
    templates = {
      rate_label_template: t("shared.exchange_rate_tabs.rate_label", from: "%{from}", to: "%{to}"),
      converted_label_template: t("shared.exchange_rate_tabs.converted_label", to: "%{to}"),
      converted_display_template: t("shared.exchange_rate_tabs.converted_display", amount: "%{amount}", currency: "%{currency}"),
      implied_rate_template: t("shared.exchange_rate_tabs.implied_rate", from: "%{from}", to: "%{to}", rate: "%{rate}", inverse: "%{inverse}"),
      market_rate_template: t("shared.exchange_rate_tabs.market_rate", from: "%{from}", to: "%{to}", rate: "%{rate}", date: "%{date}"),
      no_rate_template: t("shared.exchange_rate_tabs.no_rate", from: "%{from}", to: "%{to}")
    }

    {
      exchange_rate_form_url_value: exchange_rate_path,
      exchange_rate_form_mode_value: mode,
      exchange_rate_form_account_currencies_value: accounts.to_h { |account| [ account.id, account.currency ] }.to_json,
      **templates.transform_keys { |key| :"exchange_rate_form_#{key}_value" }
    }
  end
end
