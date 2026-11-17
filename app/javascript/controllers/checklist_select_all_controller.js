import { Controller } from "@hotwired/stimulus";

// The "All" checkbox of a checklist: it checks or clears every row, and shows checked,
// clear or mixed as the rows are. Used by the dashboard Spending filter, the transactions
// category filter and the categorize list.
//
// Optional parts: a label that says "All shown" while a search (list-filter) hides rows,
// and the box then acts on the rows shown only; an "n of total" count; a submit that is
// off, with a hint, while no row is checked (where an empty list would mean no filter).
//
// Each row change is announced (input and change events), so a cascade on the rows (the
// category-filter parents and subcategories) runs as for a click.
export default class extends Controller {
  static targets = ["all", "label", "count", "submit", "hint"];
  static values = {
    label: String,
    searchingLabel: String,
    countTemplate: String,
    // The row checkboxes
    rows: { type: String, default: ".filterable-item input[type=checkbox]" },
    // Rows left out of the count: a parent stands for its subcategories, as on the button
    uncounted: { type: String, default: "" },
  };

  connect() {
    this.refresh();
    // Rows can come and go without a change event (the categorize list drops a row once
    // it has a category), so the box and count follow the list itself too
    this.observer = new MutationObserver(() => this.refresh());
    this.observer.observe(this.element, { childList: true, subtree: true });
  }

  disconnect() {
    this.observer?.disconnect();
  }

  toggle() {
    const checked = this.allTarget.checked;
    for (const box of this.#rows({ visibleOnly: true })) {
      if (box.checked === checked) continue;
      box.checked = checked;
      box.indeterminate = false;
      box.dispatchEvent(new Event("input", { bubbles: true }));
      box.dispatchEvent(new Event("change", { bubbles: true }));
    }
    this.refresh();
  }

  // Any row change, and each keystroke in the search
  refresh() {
    const shown = this.#rows({ visibleOnly: true });
    const shownChecked = shown.filter((box) => box.checked).length;
    this.allTarget.checked = shown.length > 0 && shownChecked === shown.length;
    this.allTarget.indeterminate = shownChecked > 0 && shownChecked < shown.length;
    this.allTarget.disabled = shown.length === 0;

    if (this.hasLabelTarget) {
      const searching = shown.length < this.#rows().length;
      this.#setText(this.labelTarget, searching ? this.searchingLabelValue : this.labelValue);
    }

    if (this.hasCountTarget) {
      const counted = this.#rows().filter((box) => !this.#uncounted(box));
      const checked = counted.filter((box) => box.checked).length;
      this.#setText(this.countTarget, this.countTemplateValue.replace("%{count}", checked).replace("%{total}", counted.length));
    }

    if (this.hasSubmitTarget) {
      const none = this.#rows().every((box) => !box.checked);
      this.submitTarget.disabled = none;
      if (this.hasHintTarget) this.hintTarget.hidden = !none;
    }
  }

  #rows({ visibleOnly = false } = {}) {
    const boxes = Array.from(this.element.querySelectorAll(this.rowsValue));
    if (!visibleOnly) return boxes;
    // A row list-filter hides has display none on its .filterable-item
    return boxes.filter((box) => box.closest(".filterable-item")?.style.display !== "none");
  }

  // Writes only a change: a write is a mutation the observer would answer, forever
  #setText(element, text) {
    if (element.textContent !== text) element.textContent = text;
  }

  #uncounted(box) {
    return this.uncountedValue !== "" && box.matches(this.uncountedValue);
  }
}
