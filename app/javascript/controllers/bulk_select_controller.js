import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="bulk-select"
export default class extends Controller {
  static targets = [
    "row",
    "group",
    "selectionBar",
    "selectionBarText",
    "bulkEditDrawerHeader",
    "duplicateLink",
  ];
  static values = {
    singularLabel: String,
    pluralLabel: String,
    selectedIds: { type: Array, default: [] },
  };

  connect() {
    document.addEventListener("turbo:load", this._updateView);

    this._updateView();
  }

  disconnect() {
    document.removeEventListener("turbo:load", this._updateView);
  }

  // The rows, groups and selection bar can be replaced without this controller
  // reconnecting (a search turbo-stream or a page change replaces the
  // transactions_results frame). The selection must only ever hold rows the
  // user can see, so reconcile it whenever they change.
  rowTargetConnected() {
    this._scheduleReconcile();
  }

  rowTargetDisconnected() {
    this._scheduleReconcile();
  }

  groupTargetConnected() {
    this._scheduleReconcile();
  }

  selectionBarTargetConnected() {
    this._scheduleReconcile();
  }

  bulkEditDrawerHeaderTargetConnected(element) {
    const headingTextEl = element.querySelector("h2");
    headingTextEl.innerText = `Edit ${
      this.selectedIdsValue.length
    } ${this._pluralizedResourceName()}`;
  }

  submitBulkRequest(e) {
    // The Save button is a submit button, so Enter in a field still reaches
    // this action. Cancel its own submission: requestSubmit() below sends the
    // form once, with the selected ids added.
    e.preventDefault();
    const form = e.target.closest("form");
    const scope = e.params.scope;
    this._reconcileSelection();
    this._addHiddenFormInputsForSelectedIds(
      form,
      `${scope}[entry_ids][]`,
      this.selectedIdsValue,
    );
    form.requestSubmit();
  }

  togglePageSelection(e) {
    if (e.target.checked) {
      this._selectAll();
    } else {
      this.deselectAll();
    }
  }

  toggleGroupSelection(e) {
    const group = this.groupTargets.find((group) => group.contains(e.target));

    this._rowsForGroup(group).forEach((row) => {
      if (e.target.checked) {
        this._addToSelection(row.dataset.id);
      } else {
        this._removeFromSelection(row.dataset.id);
      }
    });
  }

  toggleRowSelection(e) {
    if (e.target.checked) {
      this._addToSelection(e.target.dataset.id);
    } else {
      this._removeFromSelection(e.target.dataset.id);
    }
  }

  deselectAll() {
    this.selectedIdsValue = [];
    this.element.querySelectorAll('input[type="checkbox"]').forEach((el) => {
      el.checked = false;
    });
  }

  selectedIdsValueChanged() {
    this._updateView();
  }

  _addHiddenFormInputsForSelectedIds(form, paramName, transactionIds) {
    this._resetFormInputs(form, paramName);

    transactionIds.forEach((id) => {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = paramName;
      input.value = id;
      form.appendChild(input);
    });
  }

  _resetFormInputs(form, paramName) {
    const existingInputs = form.querySelectorAll(`input[name='${paramName}']`);
    existingInputs.forEach((input) => input.remove());
  }

  _rowsForGroup(group) {
    return this.rowTargets.filter(
      (row) => group.contains(row) && !row.disabled,
    );
  }

  _addToSelection(idToAdd) {
    this.selectedIdsValue = Array.from(
      new Set([...this.selectedIdsValue, idToAdd]),
    );
  }

  _removeFromSelection(idToRemove) {
    this.selectedIdsValue = this.selectedIdsValue.filter(
      (id) => id !== idToRemove,
    );
  }

  _selectAll() {
    this.selectedIdsValue = this.rowTargets
      .filter((t) => !t.disabled)
      .map((t) => t.dataset.id);
  }

  // Removing and adding targets in one DOM replacement fires many callbacks,
  // so run the reconcile once, after they are all delivered.
  _scheduleReconcile() {
    if (this._reconcileScheduled) return;
    this._reconcileScheduled = true;

    queueMicrotask(() => {
      this._reconcileScheduled = false;
      if (!this.element.isConnected) return;
      this._reconcileSelection();
      this._updateView();
    });
  }

  _reconcileSelection() {
    const visibleIds = new Set(
      this.rowTargets.filter((row) => !row.disabled).map((row) => row.dataset.id),
    );
    const selectedIds = this.selectedIdsValue.filter((id) => visibleIds.has(id));

    if (selectedIds.length !== this.selectedIdsValue.length) {
      this.selectedIdsValue = selectedIds;
    }
  }

  _updateView = () => {
    if (this.hasSelectionBarTarget) this._updateSelectionBar();
    this._updateGroups();
    this._updateRows();
  };

  _updateSelectionBar() {
    const count = this.selectedIdsValue.length;
    this.selectionBarTextTarget.innerText = `${count} ${this._pluralizedResourceName()} selected`;
    this.selectionBarTarget.classList.toggle("hidden", count === 0);
    this.selectionBarTarget.querySelector("input[type='checkbox']").checked =
      count > 0;

    this._updateDuplicateLink();
  }

  // Duplicate works on exactly one selected transaction (not a trade or a valuation)
  _updateDuplicateLink() {
    if (!this.hasDuplicateLinkTarget) return;

    const row = this._selectedRow();
    const canDuplicate = row?.dataset.entryType === "Transaction";
    this.duplicateLinkTarget.classList.toggle("hidden", !canDuplicate);
    if (!canDuplicate) return;

    const url = new URL(this.duplicateLinkTarget.href, window.location.origin);
    url.searchParams.set("duplicate_entry_id", row.dataset.id);
    this.duplicateLinkTarget.href = url.toString();
  }

  _selectedRow() {
    if (this.selectedIdsValue.length !== 1) return null;

    return this.rowTargets.find(
      (row) => row.dataset.id === this.selectedIdsValue[0],
    );
  }

  _pluralizedResourceName() {
    if (this.selectedIdsValue.length === 1) {
      return this.singularLabelValue;
    }

    return this.pluralLabelValue;
  }

  _updateGroups() {
    this.groupTargets.forEach((group) => {
      const rows = this.rowTargets.filter(
        (row) => group.contains(row) && !row.disabled,
      );
      const groupSelected =
        rows.length > 0 &&
        rows.every((row) => this.selectedIdsValue.includes(row.dataset.id));
      group.querySelector("input[type='checkbox']").checked = groupSelected;
    });
  }

  _updateRows() {
    this.rowTargets.forEach((row) => {
      row.checked = this.selectedIdsValue.includes(row.dataset.id);
    });
  }
}
