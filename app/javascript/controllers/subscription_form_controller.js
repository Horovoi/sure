import { Controller } from "@hotwired/stimulus"
import evaluateAmountExpression from "utils/evaluate_amount_expression"

export default class extends Controller {
  static targets = ["nameField", "billingCycle", "monthField", "amountField", "currencySelect", "conversionHint", "conversionText"]

  static values = {
    familyCurrency: String,
    exchangeRates: Object
  }

  connect() {
    this.toggleMonthField()
    this.updateConversionHint()
  }

  serviceSelected(event) {
    const { service } = event.detail

    // Auto-fill name if empty
    if (this.hasNameFieldTarget && !this.nameFieldTarget.value.trim()) {
      this.nameFieldTarget.value = service.name
    }
  }

  serviceCleared() {
    // Optionally clear the name field when service is cleared
    // For now, we'll leave it as is so users don't lose their edits
  }

  billingCycleChanged() {
    this.toggleMonthField()
  }

  toggleMonthField() {
    if (!this.hasBillingCycleTarget || !this.hasMonthFieldTarget) return

    const isYearly = this.billingCycleTarget.value === "yearly"
    this.monthFieldTarget.classList.toggle("hidden", !isYearly)
  }

  async updateConversionHint() {
    if (!this.hasAmountFieldTarget || !this.hasCurrencySelectTarget || !this.hasConversionHintTarget || !this.hasConversionTextTarget) {
      return
    }

    // Every call supersedes the earlier ones: a slow rate fetch that finishes
    // later must not overwrite the hint for the current amount and currency
    const requestId = (this.hintRequestId = (this.hintRequestId || 0) + 1)
    const isStale = () => requestId !== this.hintRequestId

    // Read the amount the way the money field will send it ("12,50" is 12.5,
    // "120+35,5" is 155.5); anything it can't read hides the hint.
    const amount = evaluateAmountExpression(this.amountFieldTarget.value)
    const selectedCurrency = this.currencySelectTarget.value
    const familyCurrency = this.familyCurrencyValue

    // Hide hint if no amount or invalid amount
    if (amount === null || amount <= 0) {
      this.conversionHintTarget.classList.add("hidden")
      return
    }

    // Determine target currency for conversion
    // - If selected != family currency: convert to family currency
    // - If selected == family currency: convert UAH<->USD for reference
    let targetCurrency
    if (selectedCurrency !== familyCurrency) {
      targetCurrency = familyCurrency
    } else if (selectedCurrency === "UAH") {
      targetCurrency = "USD"
    } else if (selectedCurrency === "USD") {
      targetCurrency = "UAH"
    } else {
      // No conversion needed for other currencies when matching family currency
      this.conversionHintTarget.classList.add("hidden")
      return
    }

    // Get exchange rate for this currency pair
    const rateKey = `${selectedCurrency}_to_${targetCurrency}`
    let rate = this.exchangeRatesValue[rateKey]

    if (!rate) {
      // Fetch from server (which will also cache to DB)
      this.conversionTextTarget.textContent = "Fetching rate..."
      this.conversionHintTarget.classList.remove("hidden")

      try {
        const response = await fetch(`/subscriptions/fetch_exchange_rate?from=${selectedCurrency}&to=${targetCurrency}`)
        if (response.ok) {
          const data = await response.json()
          rate = data.rate
          // Cache locally for this session, also when a newer call superseded this one,
          // so that call's successors do not fetch the same pair again
          this.exchangeRatesValue = { ...this.exchangeRatesValue, [rateKey]: rate }
          if (isStale()) return
        } else {
          if (isStale()) return
          this.conversionHintTarget.classList.add("hidden")
          return
        }
      } catch (e) {
        if (isStale()) return
        this.conversionHintTarget.classList.add("hidden")
        return
      }
    }

    // Calculate converted amount
    const convertedAmount = amount * rate

    // Format the converted amount
    const formattedAmount = new Intl.NumberFormat('en-US', {
      style: 'decimal',
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    }).format(convertedAmount)

    // Update the hint text
    this.conversionTextTarget.textContent = `≈ ${formattedAmount} ${targetCurrency} at current rate`
    this.conversionHintTarget.classList.remove("hidden")
  }
}
