import { Controller } from "@hotwired/stimulus";
import evaluateAmountExpression from "utils/evaluate_amount_expression";

// Live preview for the record-pledge dialog (goal-pledges, ported from upstream).
// Reads the goal's progress and target from values and rewrites one sentence on each
// keystroke. The sentence templates come from the locale file, so the words stay in i18n.
export default class extends Controller {
  static targets = [
    "amountInput",
    "preview",
    "accountSelect",
    "helperTransfer",
    "helperManual",
  ];
  static values = {
    currentBalance: Number,
    targetAmount: Number,
    currency: String,
    templateZero: String,
    templateNonzero: String,
    templateReached: String,
  };

  connect() {
    this.update();
    this.accountChanged();
  }

  // The helper follows the selected account, not the goal: a goal funded by a cash
  // account and an investment account keeps each pledge a different way
  accountChanged() {
    if (!this.hasAccountSelectTarget) return;
    if (!this.hasHelperTransferTarget || !this.hasHelperManualTarget) return;

    const option = this.accountSelectTarget.selectedOptions[0];
    const isManual = option?.dataset.manual === "true";
    this.helperTransferTarget.hidden = isManual;
    this.helperManualTarget.hidden = !isManual;
  }

  update() {
    if (!this.hasPreviewTarget) return;

    const amount = this.#amountValue();
    const newTotal = this.currentBalanceValue + amount;
    const target = this.targetAmountValue;
    const reached = target > 0 && newTotal >= target;
    const percent = target > 0 ? Math.min(100, Math.round((newTotal / target) * 100)) : 0;

    let text;
    if (reached) {
      text = this.templateReachedValue.replaceAll("{target}", this.#money(target));
    } else if (amount === 0) {
      text = this.templateZeroValue
        .replaceAll("{percent}", percent.toString())
        .replaceAll("{current}", this.#money(this.currentBalanceValue))
        .replaceAll("{target}", this.#money(target));
    } else {
      text = this.templateNonzeroValue
        .replaceAll("{percent}", percent.toString())
        .replaceAll("{newTotal}", this.#money(newTotal))
        .replaceAll("{target}", this.#money(target));
    }

    this.previewTarget.textContent = text;
  }

  // The money field takes a comma decimal or a calculation ("12,50+4,30"), which
  // Number.parseFloat would cut short at the first comma or operator
  #amountValue() {
    if (!this.hasAmountInputTarget) return 0;

    const parsed = evaluateAmountExpression(this.amountInputTarget.value);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  }

  // Intl picks the currency's own fraction digits, so the preview never rounds what
  // the user typed
  #money(value) {
    try {
      return new Intl.NumberFormat(document.documentElement.lang || undefined, {
        style: "currency",
        currency: this.currencyValue,
      }).format(value);
    } catch {
      return `${value.toLocaleString()} ${this.currencyValue}`;
    }
  }
}
