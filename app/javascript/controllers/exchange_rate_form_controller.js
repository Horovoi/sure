import { Controller } from "@hotwired/stimulus"
import evaluateAmountExpression from "utils/evaluate_amount_expression"

// Connects to data-controller="exchange-rate-form" on the new-transaction and
// new-transfer forms (shared/_exchange_rate_tabs).
//
// When the money moves between two currencies (a transfer between accounts in
// different currencies, or a transaction in a currency other than its
// account's), the form shows two tabs:
// - "Exchange rate": the bank's rate, from the source currency into the
//   destination one;
// - "Amount received": what arrived, in the destination currency.
//
// The market rate (GET /exchange_rate, the nearest-rate rule) is only a
// placeholder: a field left blank sends nothing and the server converts at the
// market rate. Only the visible tab's field is sent, and nothing is sent when
// the currencies are the same.
export default class extends Controller {
  static targets = [
    // mode "transfer"
    "fromAccount", "toAccount",
    // mode "transaction"
    "account", "currency",
    // both
    "amount", "date", "container", "rateInput", "convertedInput",
    "rateLabel", "convertedLabel", "convertedDisplay", "impliedRateDisplay", "marketHint"
  ]

  static values = {
    url: String,
    mode: { type: String, default: "transfer" },
    accountCurrencies: Object,
    rateLabelTemplate: String,
    convertedLabelTemplate: String,
    convertedDisplayTemplate: String,
    impliedRateTemplate: String,
    marketRateTemplate: String,
    noRateTemplate: String
  }

  connect() {
    this.marketRate = null
    this.refresh()
  }

  disconnect() {
    this.abortController?.abort()
  }

  // An account, currency or date changed: show or hide the tabs and look the
  // market rate up again
  refresh() {
    const context = this.context()

    if (!context || context.from === context.to) {
      this.hide()
      return
    }

    this.currentContext = context
    this.show(context)
    this.fetchMarketRate(context)
  }

  // The amount, the rate or the received amount changed
  recalculate() {
    if (!this.currentContext || !this.hasContainerTarget || this.containerTarget.hidden) return

    const { from, to } = this.currentContext
    const amount = this.readNumber(this.hasAmountTarget ? this.amountTarget.value : "")
    const rate = this.readNumber(this.hasRateInputTarget ? this.rateInputTarget.value : "") || this.marketRate
    const converted = this.readNumber(this.hasConvertedInputTarget ? this.convertedInputTarget.value : "")

    if (this.hasConvertedDisplayTarget) {
      this.convertedDisplayTarget.textContent = amount && rate
        ? this.fill(this.convertedDisplayTemplateValue, { amount: this.formatAmount(Math.abs(amount) * rate), currency: to })
        : ""
    }

    if (this.hasImpliedRateDisplayTarget) {
      this.impliedRateDisplayTarget.textContent = amount && converted
        ? this.fill(this.impliedRateTemplateValue, {
            from, to,
            rate: this.formatRate(converted / Math.abs(amount)),
            inverse: this.formatRate(Math.abs(amount) / converted)
          })
        : ""
    }
  }

  // Before the form is sent: only the visible tab's field goes, and none when
  // the tabs are hidden (same currency)
  prepareSubmit() {
    const hidden = !this.hasContainerTarget || this.containerTarget.hidden

    for (const input of [ ...this.rateInputTargets, ...this.convertedInputTargets ]) {
      const panel = input.closest("[role=tabpanel]")
      input.disabled = hidden || (panel?.classList.contains("hidden") ?? false)
    }
  }

  // --- context ---

  context() {
    const date = this.hasDateTarget ? this.dateTarget.value : ""

    if (this.modeValue === "transaction") {
      if (!this.hasAccountTarget || !this.hasCurrencyTarget) return null

      const to = this.accountCurrenciesValue[this.accountTarget.value]
      const from = this.currencyTarget.value
      return from && to ? { from, to, date } : null
    }

    if (!this.hasFromAccountTarget || !this.hasToAccountTarget) return null

    const from = this.accountCurrenciesValue[this.fromAccountTarget.value]
    const to = this.accountCurrenciesValue[this.toAccountTarget.value]
    return from && to ? { from, to, date } : null
  }

  // --- market rate ---

  async fetchMarketRate(context) {
    this.abortController?.abort()
    this.abortController = new AbortController()
    this.marketRate = null
    this.setMarketHint("")
    this.setPlaceholder("")

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("from", context.from)
    url.searchParams.set("to", context.to)
    if (context.date) url.searchParams.set("date", context.date)

    try {
      const response = await fetch(url, { signal: this.abortController.signal, headers: { Accept: "application/json" } })
      const data = await response.json().catch(() => ({}))

      // A later change of account, currency or date superseded this lookup
      if (!this.sameContext(context, this.currentContext)) return

      if (response.ok && data.rate) {
        this.marketRate = Number(data.rate)
        this.setPlaceholder(this.formatRate(this.marketRate))
        this.setMarketHint(this.fill(this.marketRateTemplateValue, {
          from: context.from, to: context.to, rate: this.formatRate(this.marketRate), date: data.date || ""
        }))
      } else {
        this.setMarketHint(this.fill(this.noRateTemplateValue, { from: context.from, to: context.to }))
      }
    } catch (error) {
      if (error.name === "AbortError") return
      this.setMarketHint(this.fill(this.noRateTemplateValue, { from: context.from, to: context.to }))
    }

    this.recalculate()
  }

  // --- view ---

  show({ from, to }) {
    if (!this.hasContainerTarget) return

    this.containerTarget.hidden = false
    if (this.hasRateLabelTarget) this.rateLabelTarget.textContent = this.fill(this.rateLabelTemplateValue, { from, to })
    if (this.hasConvertedLabelTarget) this.convertedLabelTarget.textContent = this.fill(this.convertedLabelTemplateValue, { from, to })
    this.recalculate()
  }

  hide() {
    this.abortController?.abort()
    this.currentContext = null
    this.marketRate = null
    if (this.hasContainerTarget) this.containerTarget.hidden = true
  }

  setPlaceholder(text) {
    if (this.hasRateInputTarget) this.rateInputTarget.placeholder = text
  }

  setMarketHint(text) {
    if (this.hasMarketHintTarget) this.marketHintTarget.textContent = text
  }

  // --- helpers ---

  sameContext(a, b) {
    return !!a && !!b && a.from === b.from && a.to === b.to && a.date === b.date
  }

  readNumber(text) {
    const value = evaluateAmountExpression(String(text || ""))
    return value && value > 0 ? value : null
  }

  fill(template, params) {
    return Object.entries(params).reduce(
      (text, [ key, value ]) => text.replaceAll(`%{${key}}`, value),
      template || ""
    )
  }

  formatAmount(value) {
    return new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value)
  }

  // Enough significant digits for both 41.53 (USD to UAH) and 0.02408 (UAH to USD)
  formatRate(value) {
    if (!Number.isFinite(value) || value <= 0) return ""
    return Number(value.toPrecision(6)).toString()
  }
}
