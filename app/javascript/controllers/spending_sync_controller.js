import { Controller } from "@hotwired/stimulus";

// Keeps the inline and fullscreen Spending widgets on the same period and category
// filter. Each copy's controls reload only its own Turbo Frame; when one copy loads,
// it moves the other frame to the same URL and puts its dates in the dialog header.
export default class extends Controller {
  static values = {
    otherFrame: String,
    periodLabel: String,
  };

  connect() {
    const header = document.getElementById("spendingFullscreenPeriod");
    if (header && this.periodLabelValue) header.textContent = this.periodLabelValue;

    const ownSrc = this.element.closest("turbo-frame")?.src;
    const other = document.getElementById(this.otherFrameValue);
    // On the first page load neither frame has a src, and both show the same data.
    // When the other frame already shows this URL, the sync is done: no loop.
    if (!ownSrc || !other || this.#sameUrl(ownSrc, other.src)) return;

    other.src = ownSrc;
  }

  #sameUrl(a, b) {
    if (!a || !b) return false;
    return new URL(a, window.location.href).href === new URL(b, window.location.href).href;
  }
}
