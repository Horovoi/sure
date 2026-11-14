import { Controller } from "@hotwired/stimulus";
import { CurrenciesService } from "services/currencies_service";

// Connects to data-controller="money-field"
// when currency select change, update the input value with the correct placeholder and step
export default class extends Controller {
  static targets = ["amount", "currency", "symbol"];

  handleCurrencyChange(e) {
    const selectedCurrency = e.target.value;
    this.updateAmount(selectedCurrency);
  }

  updateAmount(currency) {
    // Currency lookups can finish out of order; only the latest one applies
    const requestId = (this.currencyRequestId = (this.currencyRequestId || 0) + 1);

    new CurrenciesService().get(currency).then((currency) => {
      if (requestId !== this.currencyRequestId) return;

      this.amountTarget.step = currency.step;

      // The input value is a string, so parse it before checking it
      const amount = Number.parseFloat(this.amountTarget.value);
      if (Number.isFinite(amount)) {
        this.amountTarget.value = amount.toFixed(currency.default_precision);
      }

      this.symbolTarget.innerText = currency.symbol;
    });
  }
}
