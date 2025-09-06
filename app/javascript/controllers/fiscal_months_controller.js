import { Controller } from "@hotwired/stimulus";

// Controls enabling/disabling the fiscal day selector based on the toggle.
export default class extends Controller {
  static targets = ["toggle", "day"]; // checkbox + select

  connect() {
    this.#sync();
  }

  handleToggle() {
    this.#sync();
  }

  #sync() {
    try {
      const enabled = this.toggleTarget?.checked;
      if (this.hasDayTarget) {
        this.dayTarget.disabled = !enabled;
      }
    } catch (e) {
      // no-op: be resilient if markup changes
    }
  }
}

