import { Controller } from "@hotwired/stimulus";

// Clears all query-related fields within a form and submits it.
// Usage: add a button with
// data-controller="clear-search"
// data-clear-search-form-id-value="transactions-search"
// data-action="click->clear-search#reset"
export default class extends Controller {
  static values = { formId: String };

  reset() {
    const form = this.#findForm();
    if (!form) return;

    // Clear all fields starting with q[...]
    const fields = form.querySelectorAll('[name^="q["], [name="q"]');
    fields.forEach((el) => this.#clearField(el));

    // Keep per_page and other non-q fields unchanged

    // Submit and focus back on search box
    const search = form.querySelector('[name="q[search]"]');
    form.requestSubmit();
    if (search) search.focus();
  }

  #findForm() {
    if (this.hasFormIdValue) {
      const el = document.getElementById(this.formIdValue);
      if (el && el.tagName === "FORM") return el;
    }
    return this.element.closest("form");
  }

  #clearField(el) {
    const type = (el.type || "").toLowerCase();
    switch (type) {
      case "checkbox":
      case "radio":
        el.checked = false;
        break;
      case "select-one":
        // Prefer blank option if available
        if ([...el.options].some((o) => o.value === "")) {
          el.value = "";
        } else {
          el.selectedIndex = -1;
        }
        el.dispatchEvent(new Event("change", { bubbles: true }));
        break;
      case "select-multiple":
        [...el.options].forEach((o) => (o.selected = false));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        break;
      default:
        el.value = "";
        el.dispatchEvent(new Event("input", { bubbles: true }));
    }
  }
}

