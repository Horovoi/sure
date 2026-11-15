import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "iconDefault", "iconSuccess"];

  copy(event) {
    event.preventDefault();
    // The Clipboard API exists only in secure contexts (https or localhost).
    // On a plain-http LAN address, select the text so it can be copied by hand.
    if (!navigator.clipboard) {
      this.#selectSource();
      return;
    }
    if (this.sourceTarget?.textContent) {
      navigator.clipboard
        .writeText(this.sourceTarget.textContent)
        .then(() => {
          this.showSuccess();
        })
        .catch((error) => {
          console.error("Failed to copy text: ", error);
        });
    }
  }

  #selectSource() {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(this.sourceTarget);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  showSuccess() {
    // Some callers have no success icons to swap
    if (!this.hasIconDefaultTarget || !this.hasIconSuccessTarget) return;
    this.iconDefaultTarget.classList.add("hidden");
    this.iconSuccessTarget.classList.remove("hidden");
    setTimeout(() => {
      this.iconDefaultTarget.classList.remove("hidden");
      this.iconSuccessTarget.classList.add("hidden");
    }, 3000);
  }
}
