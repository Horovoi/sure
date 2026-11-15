import { Controller } from "@hotwired/stimulus";

// The one move-money dialog of the budget categories step (upstream 3d6a8d8b6). Each
// row's move button opens it with that row as the source. DS::Dialog does the focus
// trap, Escape and click-outside; this controller fills in the source and disables the
// destinations the server refuses: the row itself, its parent and its subcategories (a
// parent's amount is built from its subcategories').
export default class extends Controller {
  static targets = [
    "dialog",
    "fromId",
    "fromName",
    "available",
    "toSelect",
    "amount",
    "submit",
    "noDestination",
    "error",
  ];

  open({ params }) {
    this.fromIdTarget.value = params.fromId;
    this.fromNameTarget.textContent = params.fromName;
    this.availableTarget.textContent = params.available;
    this.amountTarget.value = "";
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = "";
      this.errorTarget.classList.add("hidden");
    }

    this.#refreshOptions(
      String(params.fromId),
      String(params.categoryId),
      String(params.parentId || ""),
    );
    this.dialogTarget.showModal();
    this.amountTarget.focus();
  }

  close() {
    const dialog = this.#dialogController();
    if (dialog) {
      dialog.close();
    } else {
      this.dialogTarget.close();
    }
  }

  // A refused move shows its reason in a notification and keeps the dialog open
  submitEnd(event) {
    if (event.detail?.success) this.close();
  }

  #refreshOptions(fromId, categoryId, parentId) {
    let firstEnabled = null;

    for (const option of this.toSelectTarget.options) {
      const optionCategoryId = option.dataset.categoryId;
      const optionParentId = option.dataset.parentId || "";

      option.disabled =
        option.value === fromId ||
        (parentId !== "" && optionCategoryId === parentId) ||
        optionParentId === categoryId;

      if (!option.disabled && firstEnabled === null) firstEnabled = option;
    }

    if (firstEnabled) this.toSelectTarget.value = firstEnabled.value;

    // With nowhere to send the money, say so instead of a submit that can only fail
    const hasDestination = firstEnabled !== null;
    this.submitTarget.disabled = !hasDestination;
    this.toSelectTarget.disabled = !hasDestination;
    this.amountTarget.disabled = !hasDestination;
    this.noDestinationTarget.classList.toggle("hidden", hasDestination);
  }

  #dialogController() {
    return this.application.getControllerForElementAndIdentifier(
      this.dialogTarget,
      "DS--dialog",
    );
  }
}
