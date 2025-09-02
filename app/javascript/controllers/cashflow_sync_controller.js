import { Controller } from "@hotwired/stimulus";

// Keeps compact and fullscreen Sankey subcategory toggles in sync
export default class extends Controller {
  connect() {
    // When this element (compact toggle) appears after a Turbo Frame refresh,
    // broadcast its current state to the fullscreen chart + toggle.
    this.broadcast();
  }

  broadcast() {
    const checked = this.element?.checked;

    // Get latest datasets from the compact chart element
    const compactChart = document.getElementById("cashflowSankeyChart");
    let withSub = null, withoutSub = null, currency = null;
    if (compactChart) {
      const ds = compactChart.dataset;
      try { withSub = ds.sankeyChartWithSubcategoriesValue ? JSON.parse(ds.sankeyChartWithSubcategoriesValue) : null; } catch {}
      try { withoutSub = ds.sankeyChartWithoutSubcategoriesValue ? JSON.parse(ds.sankeyChartWithoutSubcategoriesValue) : null; } catch {}
      currency = ds.sankeyChartCurrencySymbolValue || null;
    }

    // Update fullscreen chart if present
    const chartEl = document.getElementById("cashflowSankeyChartFullscreen");
    if (chartEl) {
      // Replace datasets (period) and set the desired mode
      chartEl.dispatchEvent(new CustomEvent("sankey:set-datasets", {
        detail: {
          withSubcategories: withSub,
          withoutSubcategories: withoutSub,
          showSubcategories: checked,
          currencySymbol: currency,
        }
      }));
    }

    // Update fullscreen toggle UI if present
    const overlayToggle = document.getElementById("cashflow_show_subcategories_dialog");
    if (overlayToggle) {
      overlayToggle.checked = !!checked;
    }
  }
}
