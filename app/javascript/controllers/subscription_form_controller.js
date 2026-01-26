import { Controller } from "@hotwired/stimulus"

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

    const amount = parseFloat(this.amountFieldTarget.value)
    const selectedCurrency = this.currencySelectTarget.value
    const familyCurrency = this.familyCurrencyValue

    // Hide hint if same currency, no amount, or invalid amount
    if (!amount || amount <= 0 || selectedCurrency === familyCurrency || isNaN(amount)) {
      this.conversionHintTarget.classList.add("hidden")
      return
    }

    // Get exchange rate for this currency pair
    let rate = this.exchangeRatesValue[selectedCurrency]

    if (!rate) {
      // Fetch from server (which will also cache to DB)
      this.conversionTextTarget.textContent = "Fetching rate..."
      this.conversionHintTarget.classList.remove("hidden")

      try {
        const response = await fetch(`/subscriptions/fetch_exchange_rate?from=${selectedCurrency}`)
        if (response.ok) {
          const data = await response.json()
          rate = data.rate
          // Cache locally for this session
          this.exchangeRatesValue = { ...this.exchangeRatesValue, [selectedCurrency]: rate }
        } else {
          this.conversionHintTarget.classList.add("hidden")
          return
        }
      } catch (e) {
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
    this.conversionTextTarget.textContent = `${formattedAmount} ${familyCurrency} at current rate`
    this.conversionHintTarget.classList.remove("hidden")
  }
}
