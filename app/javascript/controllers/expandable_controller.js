import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="expandable"
//
// Reopens a cramped card (a wide table, a chart) in a roomier modal. The trigger sits
// outside the <dialog>, so it is out of scope for the DS--dialog controller's own
// actions; this thin wrapper bridges the two.
//
// Native <dialog> remembers the previously focused element across showModal() and
// close(), so focus returns to the expand button on its own.
export default class extends Controller {
  static targets = ["dialog"];

  open(event) {
    event?.preventDefault();

    const dialog = this.hasDialogTarget
      ? this.dialogTarget
      : this.element.querySelector("dialog");

    if (!dialog || dialog.open || typeof dialog.showModal !== "function") return;

    dialog.showModal();
  }
}
