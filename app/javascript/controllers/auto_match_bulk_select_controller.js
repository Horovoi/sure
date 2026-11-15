import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="auto-match-bulk-select"
// Row selection on the transfer auto-match review page. Shows the bulk bar while any row
// is selected and, on submit, copies the selected transfer ids into the bulk form (the
// rows sit outside it, because each row's own Confirm and Reject are forms).
export default class extends Controller {
  static targets = ["selectAll", "row", "bar", "count"];
  static values = { countTemplate: String };

  connect() {
    this.#update();
  }

  toggleAll(event) {
    for (const row of this.rowTargets) row.checked = event.target.checked;
    this.#update();
  }

  toggleRow() {
    this.#update();
  }

  populateIds(event) {
    const form = event.target;
    for (const input of form.querySelectorAll("input[name='transfer_ids[]']")) input.remove();

    for (const id of this.#selectedIds()) {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = "transfer_ids[]";
      input.value = id;
      form.appendChild(input);
    }
  }

  #selectedIds() {
    return this.rowTargets.filter((row) => row.checked).map((row) => row.dataset.id);
  }

  #update() {
    const selected = this.#selectedIds().length;

    if (this.hasSelectAllTarget) {
      const all = this.rowTargets.length > 0 && selected === this.rowTargets.length;
      this.selectAllTarget.checked = all;
      this.selectAllTarget.indeterminate = selected > 0 && !all;
    }
    if (this.hasBarTarget) this.barTarget.classList.toggle("hidden", selected === 0);
    if (this.hasCountTarget) {
      this.countTarget.textContent = this.countTemplateValue.replace("%{count}", selected);
    }
  }
}
