import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["child"];

  connect() {
    this.syncFromParents();
  }

  toggleChildren(event) {
    const groupId = event.params.group;
    if (!groupId) return;

    this.updateChildren(groupId, event.target.checked);
  }

  syncFromParents() {
    const parentCheckboxes = this.element.querySelectorAll(
      "[data-category-filter-group-param]",
    );

    parentCheckboxes.forEach((parent) => {
      const groupId = parent.dataset.categoryFilterGroupParam;
      if (!groupId) return;

      if (parent.checked) {
        this.updateChildren(groupId, true);
      }
    });
  }

  updateChildren(groupId, checked) {
    this.childTargets.forEach((child) => {
      if (child.dataset.categoryFilterGroupId === String(groupId)) {
        if (child.checked !== checked) {
          child.checked = checked;
        }
      }
    });
  }
}
