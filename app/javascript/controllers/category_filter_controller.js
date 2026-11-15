import { Controller } from "@hotwired/stimulus";

// Cascading parent/subcategory checkboxes for a category filter (the transactions
// filter and the dashboard Spending widget).
//
// A checked parent covers all of its subcategories on the server (a parent value in the
// submitted params includes every child), with no way to leave one child out. So a
// parent may stay checked, and be submitted, only while every child is checked:
// unchecking one child unchecks the parent (shown as indeterminate), else the
// deselected child's transactions would still be counted.
export default class extends Controller {
  static targets = ["parent", "child"];

  connect() {
    this.syncFromParents();
    // Only marks partly selected groups: a group whose children the server rendered all
    // checked keeps its parent as it was, so the parent's own transactions are not added
    this.parentTargets.forEach((parent) =>
      this.#syncParent(parent.dataset.categoryFilterGroupParam, { allowCheck: false }),
    );
    this.element.addEventListener("change", this.#onChange);
  }

  disconnect() {
    this.element.removeEventListener("change", this.#onChange);
  }

  toggleChildren(event) {
    const groupId = event.params.group;
    if (!groupId) return;

    event.target.indeterminate = false;
    this.updateChildren(groupId, event.target.checked);
  }

  // A parent checked by the server (a link that names only the parent) checks its
  // children, so the pass in connect does not read it as partly selected
  syncFromParents() {
    this.parentTargets.forEach((parent) => {
      const groupId = parent.dataset.categoryFilterGroupParam;
      if (groupId && parent.checked) this.updateChildren(groupId, true);
    });
  }

  updateChildren(groupId, checked) {
    this.#childrenOf(groupId).forEach((child) => {
      if (child.checked !== checked) child.checked = checked;
    });
  }

  #onChange = (event) => {
    const groupId = event.target.dataset?.categoryFilterGroupId;
    if (groupId && this.childTargets.includes(event.target)) this.#syncParent(groupId);
  };

  #childrenOf(groupId) {
    return this.childTargets.filter((child) => child.dataset.categoryFilterGroupId === String(groupId));
  }

  #syncParent(groupId, { allowCheck = true } = {}) {
    if (!groupId) return;

    const parent = this.parentTargets.find((target) => target.dataset.categoryFilterGroupParam === String(groupId));
    const children = this.#childrenOf(groupId);
    if (!parent || children.length === 0) return;

    const checkedCount = children.filter((child) => child.checked).length;
    const allChecked = checkedCount === children.length;
    if (allowCheck || !allChecked) parent.checked = allChecked;
    parent.indeterminate = checkedCount > 0 && checkedCount < children.length;
  }
}
