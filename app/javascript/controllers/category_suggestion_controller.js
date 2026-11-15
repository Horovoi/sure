import { Controller } from "@hotwired/stimulus";

// New-transaction form: picking a past name from the name autocomplete also
// picks the category used most often with that name. A later picked name
// replaces a category set this way, or clears it when that name has no usual
// category. A category the user picked by hand (or one already set when the
// form opened, such as a duplicated transaction's) is never changed.
export default class extends Controller {
  static targets = ["categoryField", "name"];

  connect() {
    this.userPickedCategory = this.#hasCategorySelection();
    this.applyingSuggestion = false;
  }

  // The combobox keeps the name in a hidden field that async options can update
  // after the user typed; the visible text is what the user means to save.
  syncName(event) {
    if (this.hasNameTarget) event.formData.set("entry[name]", this.nameTarget.value);
  }

  onCategorySelected(event) {
    if (this.applyingSuggestion) return;
    if (!event.target.matches('[data-category-select-target="hiddenInput"]')) return;

    this.userPickedCategory = true;
  }

  onNameSuggestionSelected(event) {
    // Leaving the field after typing part of a name also fires a selection;
    // only a name picked from the list (value equals its display) counts.
    const { value, display } = event.detail;
    if (!value || value !== display) return;

    const option = event.target.querySelector(
      `[role="option"][data-value="${CSS.escape(value)}"]`,
    );
    if (!option) return;

    const categoryId = option.querySelector("[data-category-id]")?.dataset.categoryId;
    this.#selectCategoryOption(categoryId || "");
  }

  #hasCategorySelection() {
    return !!this.#categoryHiddenInput()?.value;
  }

  #categoryHiddenInput() {
    return this.hasCategoryFieldTarget
      ? this.categoryFieldTarget.querySelector('[data-category-select-target="hiddenInput"]')
      : null;
  }

  // An empty id picks the picker's blank row, which clears the category
  #selectCategoryOption(categoryId) {
    if (this.userPickedCategory || !this.hasCategoryFieldTarget) return;

    const option = this.categoryFieldTarget.querySelector(
      `[data-category-select-target="option"][data-category-id="${CSS.escape(String(categoryId))}"]`,
    );
    if (!option) return;

    this.applyingSuggestion = true;
    try {
      option.click();
    } finally {
      this.applyingSuggestion = false;
    }
  }
}
