import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="confirm-dialog"
// See javascript/controllers/application.js for how this is wired up
export default class extends Controller {
  static targets = ["title", "subtitle", "confirmButton"];

  // The dialog markup renders the translated defaults; keep them for
  // confirmations that leave out a title, body or button label.
  connect() {
    this.defaults = {
      title: this.titleTarget.textContent.trim(),
      body: this.subtitleTarget.textContent.trim(),
      confirmText: this.confirmButtonTargets[0]?.textContent.trim(),
    };
  }

  handleConfirm(rawData) {
    const data = this.#normalizeRawData(rawData);

    this.#prepareDialog(data);

    this.element.showModal();

    return new Promise((resolve) => {
      this.element.addEventListener(
        "close",
        () => {
          const isConfirmed = this.element.returnValue === "confirm";
          resolve(isConfirmed);
        },
        { once: true },
      );
    });
  }

  #prepareDialog(data) {
    const variant = data.variant || "primary";

    this.confirmButtonTargets.forEach((button) => {
      if (button.dataset.variant === variant) {
        button.removeAttribute("hidden");
      } else {
        button.setAttribute("hidden", true);
      }

      button.textContent = data.confirmText || this.defaults.confirmText;
    });

    this.titleTarget.textContent = data.title || this.defaults.title;
    // Text, never HTML: bodies interpolate record names (merchants, accounts,
    // imports) that come from imports, providers and other family members,
    // however the caller built the confirmation.
    this.subtitleTarget.textContent = data.body || this.defaults.body;
  }

  // If data is a string, it's the title.  Otherwise, return the parsed object.
  #normalizeRawData(rawData) {
    try {
      const parsed = JSON.parse(rawData);

      if (typeof parsed === "boolean") {
        return {};
      }

      return parsed;
    } catch (e) {
      return { title: rawData };
    }
  }
}
