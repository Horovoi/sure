import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="breakdown-list" (Reports > Activity Breakdown).
//
// Opens and closes the parts of one income or expense list that start hidden:
// a row's details (its transactions, average and subcategories) and the rows
// past the top of the list. Each toggle is a button whose aria-expanded drives
// its own icon and labels through CSS; this only flips that state and the
// hidden attribute of what it controls.
export default class extends Controller {
  static targets = ["extra"];

  toggleRow(event) {
    const button = event.currentTarget;
    const panel = document.getElementById(button.getAttribute("aria-controls"));
    if (!panel) return;

    const open = this.#flip(button);
    panel.hidden = !open;
  }

  toggleTail(event) {
    const open = this.#flip(event.currentTarget);
    for (const row of this.extraTargets) row.hidden = !open;
  }

  #flip(button) {
    const open = button.getAttribute("aria-expanded") !== "true";
    button.setAttribute("aria-expanded", String(open));
    return open;
  }
}
