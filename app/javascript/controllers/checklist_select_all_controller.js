import { Controller } from "@hotwired/stimulus";

// The "All" row of a checklist filter (pages/dashboard/filter_popover): one checkbox that
// checks or clears every row, shown checked, clear or mixed as the rows are, with a
// "n of total" count beside it. While a search hides rows it acts on the rows shown, and
// says so. With no row checked the submit is off: an empty list would mean no filter.
//
// Each row change is announced (input and change events), so a cascade on the rows (the
// category-filter parents and subcategories) runs as for a click.
export default class extends Controller {
  static targets = ["all", "label", "count", "submit", "hint"];
  static values = {
    label: String,
    searchingLabel: String,
    countTemplate: String,
    // Rows left out of the count: a parent stands for its subcategories, as on the button
    uncounted: { type: String, default: "" },
  };

  connect() {
    this.refresh();
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

    const searching = shown.length < this.#rows().length;
    this.labelTarget.textContent = searching ? this.searchingLabelValue : this.labelValue;

    const counted = this.#rows().filter((box) => !this.#uncounted(box));
    const checked = counted.filter((box) => box.checked).length;
    this.countTarget.textContent = this.countTemplateValue
      .replace("%{count}", checked)
      .replace("%{total}", counted.length);

    const none = this.#rows().every((box) => !box.checked);
    this.submitTarget.disabled = none;
    this.hintTarget.hidden = !none;
  }

  #rows({ visibleOnly = false } = {}) {
    const boxes = Array.from(this.element.querySelectorAll(".filterable-item input[type=checkbox]"));
    if (!visibleOnly) return boxes;
    return boxes.filter((box) => box.closest(".filterable-item").style.display !== "none");
  }

  #uncounted(box) {
    return this.uncountedValue !== "" && box.matches(this.uncountedValue);
  }
}
