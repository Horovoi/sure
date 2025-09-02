import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="fullscreen"
export default class extends Controller {
  static values = {
    targetId: String,
  };

  open = (e) => {
    if (e) e.preventDefault();
    const id = this.hasTargetIdValue ? this.targetIdValue : null;
    if (!id) return;
    const dialog = document.getElementById(id);
    if (dialog && typeof dialog.showModal === "function") {
      dialog.showModal();
    }
  };

  toggleSubcategories = (e) => {
    const checked = e?.target?.checked;
    const targetId = this.hasTargetIdValue ? this.targetIdValue : e?.target?.dataset?.fullscreenTargetIdValue;
    if (!targetId) return;
    const chartEl = document.getElementById(targetId);
    if (!chartEl) return;
    chartEl.dispatchEvent(new CustomEvent("sankey:set-subcategories", { detail: { showSubcategories: checked } }));

    // Also update the compact card behind via its existing form
    const compactToggle = document.getElementById("cashflow_show_subcategories");
    if (compactToggle) {
      compactToggle.checked = checked;
      // Trigger auto-submit on its form to update the cashflow_sankey_section frame
      const ev = new Event("change", { bubbles: true });
      compactToggle.dispatchEvent(ev);
    }
  };
}
