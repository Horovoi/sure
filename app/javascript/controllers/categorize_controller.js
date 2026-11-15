import { Controller } from "@hotwired/stimulus";

// The categorize wizard (transactions/categorizes/show): the rule toggle, the
// editable "name contains" text with its preview, and the per-row category pick.
export default class extends Controller {
  static targets = [
    "createRuleCheckbox",
    "ruleDetails",
    "filterDisplay",
    "filterEditTrigger",
    "filterEditArea",
    "filterInput",
    "groupingKeyHidden",
  ];

  static values = {
    assignEntryUrl: String,
    previewRuleUrl: String,
    position: Number,
    transactionType: String,
  };

  connect() {
    this.toggleRuleDetails();
  }

  disconnect() {
    clearTimeout(this.previewTimer);
  }

  // A rule matches the whole group, so leaving a row out (or picking a category
  // for one row) turns the rule off.
  uncheckRule() {
    if (!this.hasCreateRuleCheckboxTarget) return;

    this.createRuleCheckboxTarget.checked = false;
    this.toggleRuleDetails();
  }

  toggleRuleDetails() {
    if (!this.hasRuleDetailsTarget || !this.hasCreateRuleCheckboxTarget) return;

    const enabled = this.createRuleCheckboxTarget.checked;
    this.ruleDetailsTarget.classList.toggle("opacity-40", !enabled);
    if (this.hasFilterInputTarget) this.filterInputTarget.disabled = !enabled;
    if (this.hasFilterEditTriggerTarget) this.filterEditTriggerTarget.disabled = !enabled;
  }

  startFilterEdit() {
    this.filterDisplayTarget.classList.add("hidden");
    this.filterEditTriggerTarget.classList.add("hidden");
    this.filterEditAreaTarget.classList.remove("hidden");
    this.filterEditAreaTarget.classList.add("flex");
    this.filterInputTarget.focus();
    this.filterInputTarget.select();
  }

  confirmFilterEdit(event) {
    // Enter in the text box must not submit the group form
    event.preventDefault();
    event.stopPropagation();

    const value = this.filterInputTarget.value.replace(/\s+/g, " ").trim();
    if (!value) return;

    this.filterDisplayTarget.textContent = `"${value}"`;
    this.groupingKeyHiddenTarget.value = value;
    this.closeFilterEdit();
    this.preview(value);
  }

  cancelFilterEdit(event) {
    event.preventDefault();
    event.stopPropagation();

    this.filterInputTarget.value = this.groupingKeyHiddenTarget.value;
    this.closeFilterEdit();
  }

  closeFilterEdit() {
    this.filterEditAreaTarget.classList.add("hidden");
    this.filterEditAreaTarget.classList.remove("flex");
    this.filterDisplayTarget.classList.remove("hidden");
    this.filterEditTriggerTarget.classList.remove("hidden");
  }

  preview(filter) {
    clearTimeout(this.previewTimer);
    this.previewTimer = setTimeout(() => {
      const url = new URL(this.previewRuleUrlValue, window.location.origin);
      url.searchParams.set("filter", filter);
      url.searchParams.set("position", this.positionValue);
      url.searchParams.set("transaction_type", this.transactionTypeValue);

      this.fetchStream(url.toString(), { method: "GET" }).catch((error) =>
        console.error("Rule preview failed:", error),
      );
    }, 300);
  }

  assignEntry(event) {
    const select = event.target;
    const categoryId = select.value;
    if (!categoryId) return;

    this.uncheckRule();

    const body = new FormData();
    body.append("categorize[entry_id]", select.dataset.entryId);
    body.append("categorize[category_id]", categoryId);
    body.append("categorize[position]", this.positionValue);
    // The rows still on the page; the server answers which of them are left
    this.element
      .querySelectorAll("input[name='categorize[all_entry_ids][]']")
      .forEach((input) => body.append("categorize[all_entry_ids][]", input.value));

    select.disabled = true;
    this.fetchStream(this.assignEntryUrlValue, { method: "PATCH", body }).catch((error) => {
      console.error("Category assignment failed:", error);
      select.disabled = false;
      select.value = "";
    });
  }

  async fetchStream(url, options) {
    const response = await fetch(url, {
      ...options,
      credentials: "same-origin",
      headers: {
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
        Accept: "text/vnd.turbo-stream.html",
      },
    });
    if (!response.ok) throw new Error(response.statusText);

    Turbo.renderStreamMessage(await response.text());
  }
}
