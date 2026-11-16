import { Controller } from "@hotwired/stimulus";
import openDialog from "utils/open_dialog";

// Connects to data-controller="fullscreen"
export default class extends Controller {
  static values = {
    targetId: String,
  };

  open = (e) => {
    if (e) e.preventDefault();
    const id = this.hasTargetIdValue ? this.targetIdValue : null;
    if (!id) return;
    openDialog(document.getElementById(id), this.application);
  };

  toggleSubcategories = (e) => {
    const checked = e?.target?.checked;
    const targetId = this.hasTargetIdValue ? this.targetIdValue : e?.target?.dataset?.fullscreenTargetIdValue;
    if (!targetId) return;
    const chartEl = document.getElementById(targetId);
    if (!chartEl) return;
    chartEl.dispatchEvent(new CustomEvent("sankey:set-subcategories", { detail: { showSubcategories: checked } }));

    // Also switch the inline card behind; its toggle's change handler
    // (cashflow-sync) redraws the inline chart without a request
    const compactToggle = document.getElementById("cashflow_show_subcategories");
    if (compactToggle && compactToggle.checked !== checked) {
      compactToggle.checked = checked;
      compactToggle.dispatchEvent(new Event("change", { bubbles: true }));
    }
  };
}
