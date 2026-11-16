import { Controller } from "@hotwired/stimulus";

// The split editor (splits/_form): parts that must add up to the transaction's total.
// Amounts are counted in minor units (cents) so 0.1 + 0.2 is never 0.30000000000000004.
// The server checks the same sum again (Entry::Splittable).
export default class extends Controller {
  static targets = ["rows", "template", "part", "amount", "remaining", "submit"];
  static values = {
    total: Number, // the transaction's amount in minor units, always positive
    precision: Number,
    currency: String,
    nextIndex: Number,
    balancedText: String,
    leftText: String,
    overText: String,
    minPartsText: String,
    zeroPartText: String,
  };

  connect() {
    this.recalculate();
  }

  add() {
    const html = this.templateTarget.innerHTML.replaceAll(
      "__INDEX__",
      String(this.nextIndexValue),
    );
    this.nextIndexValue += 1;
    this.rowsTarget.insertAdjacentHTML("beforeend", html);

    const added = this.partTargets[this.partTargets.length - 1];
    const amount = added.querySelector("[data-split-editor-target='amount']");
    const remaining = this.remainingMinor();
    if (amount && remaining > 0) amount.value = this.format(remaining);

    this.recalculate();
    added.querySelector("input[type='text']")?.focus();
  }

  remove(event) {
    if (this.partTargets.length <= 2) return;

    const part = event.target.closest("[data-split-editor-target='part']");
    const index = this.partTargets.indexOf(part);
    part.remove();
    this.recalculate();

    // Keep the keyboard where it was: on the next part's name, or the add button
    const next = this.partTargets[Math.min(index, this.partTargets.length - 1)];
    next?.querySelector("input[type='text']")?.focus();
  }

  // "Rest here": this part takes whatever is not assigned yet
  fill(event) {
    const part = event.target.closest("[data-split-editor-target='part']");
    const input = part.querySelector("[data-split-editor-target='amount']");
    const updated = this.toMinor(input.value) + this.remainingMinor();
    input.value = this.format(updated);
    this.recalculate();
    input.focus();
  }

  submit(event) {
    if (!this.isValid()) event.preventDefault();
  }

  recalculate() {
    const remaining = this.remainingMinor();
    const status = this.statusFor(remaining);

    this.remainingTarget.textContent = status.text;
    this.remainingTarget.dataset.state = status.state;

    for (const input of this.amountTargets) {
      const empty = input.value.trim() === "" || this.toMinor(input.value) === 0;
      input.setAttribute("aria-invalid", empty && input.value.trim() !== "" ? "true" : "false");
    }

    const removable = this.partTargets.length > 2;
    for (const button of this.element.querySelectorAll("[data-split-editor-remove]")) {
      button.disabled = !removable;
    }
    for (const button of this.element.querySelectorAll("[data-split-editor-fill]")) {
      button.disabled = remaining === 0;
    }

    if (this.hasSubmitTarget) this.submitTarget.disabled = !this.isValid();
  }

  // private

  isValid() {
    if (this.partTargets.length < 2) return false;
    if (this.amountTargets.some((input) => this.toMinor(input.value) === 0)) return false;
    return this.remainingMinor() === 0;
  }

  statusFor(remaining) {
    if (this.partTargets.length < 2) return { state: "invalid", text: this.minPartsTextValue };
    if (remaining > 0) {
      return { state: "left", text: this.leftTextValue.replace("%{amount}", this.money(remaining)) };
    }
    if (remaining < 0) {
      return { state: "over", text: this.overTextValue.replace("%{amount}", this.money(-remaining)) };
    }
    if (this.amountTargets.some((input) => this.toMinor(input.value) === 0)) {
      return { state: "invalid", text: this.zeroPartTextValue };
    }
    return { state: "balanced", text: this.balancedTextValue };
  }

  remainingMinor() {
    const assigned = this.amountTargets.reduce((sum, input) => sum + this.toMinor(input.value), 0);
    return this.totalValue - assigned;
  }

  toMinor(value) {
    const number = Number.parseFloat(String(value).replace(",", "."));
    if (!Number.isFinite(number)) return 0;
    return Math.round(number * 10 ** this.precisionValue);
  }

  format(minor) {
    return (minor / 10 ** this.precisionValue).toFixed(this.precisionValue);
  }

  money(minor) {
    const amount = minor / 10 ** this.precisionValue;
    try {
      return new Intl.NumberFormat(document.documentElement.lang || "en", {
        style: "currency",
        currency: this.currencyValue,
        minimumFractionDigits: this.precisionValue,
        maximumFractionDigits: this.precisionValue,
      }).format(amount);
    } catch {
      return `${this.format(minor)} ${this.currencyValue}`;
    }
  }
}
