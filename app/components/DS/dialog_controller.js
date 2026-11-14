import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="dialog"
export default class extends Controller {
  static targets = ["content"]

  static values = {
    autoOpen: { type: Boolean, default: false },
    reloadOnClose: { type: Boolean, default: false },
  };

  connect() {
    this.element.addEventListener("cancel", this.handleCancel);
    document.addEventListener("turbo:before-cache", this.handleBeforeCache);

    // A dialog restored from a snapshot keeps the `open` attribute but is no
    // longer modal (no backdrop, page behind still interactive). Reopen it
    // properly instead of leaving it half-open.
    if (this.element.open && !this.element.matches(":modal")) {
      this.element.close();
    }

    if (this.element.open) return;
    if (this.autoOpenValue) {
      this.element.showModal();
    }
  }

  disconnect() {
    this.element.removeEventListener("cancel", this.handleCancel);
    document.removeEventListener("turbo:before-cache", this.handleBeforeCache);
  }

  // If the user clicks anywhere outside of the visible content, close the dialog
  clickOutside(e) {
    if (!this.contentTarget.contains(e.target)) {
      this.close();
    }
  }

  close() {
    this.element.close();

    if (this.reloadOnCloseValue) {
      Turbo.visit(window.location.href);
    }
  }

  // Esc closes the dialog natively; route it through close() so
  // reloadOnClose still applies
  handleCancel = (event) => {
    if (!this.reloadOnCloseValue) return;

    event.preventDefault();
    this.close();
  };

  // Never cache an open dialog: the snapshot cannot keep it modal. An
  // auto-open dialog opens again, as a modal, when the page is restored.
  handleBeforeCache = () => {
    if (this.element.open) this.element.close();
  };
}
