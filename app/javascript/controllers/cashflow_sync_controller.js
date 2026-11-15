import { Controller } from "@hotwired/stimulus";

// Keeps the inline and fullscreen cash flow Sankeys in step: the subcategory
// mode, and the data and period after the inline card's frame reloads.
export default class extends Controller {
  connect() {
    // When this element (the inline toggle) appears after a Turbo Frame
    // refresh, send its state and the new data to the fullscreen chart.
    this.broadcast();
  }

  broadcast() {
    const checked = !!this.element?.checked;

    const compactChart = document.getElementById("cashflowSankeyChart");
    compactChart?.dispatchEvent(
      new CustomEvent("sankey:set-subcategories", { detail: { showSubcategories: checked } }),
    );

    const detail = { showSubcategories: checked };
    if (compactChart) {
      const ds = compactChart.dataset;
      try {
        detail.data = ds.sankeyChartDataValue ? JSON.parse(ds.sankeyChartDataValue) : null;
      } catch {
        detail.data = null;
      }
      detail.currencySymbol = ds.sankeyChartCurrencySymbolValue || null;
      detail.startDate = ds.sankeyChartStartDateValue || null;
      detail.endDate = ds.sankeyChartEndDateValue || null;

      const headerEl = document.getElementById("cashflowFullscreenPeriod");
      if (headerEl && ds.periodText) headerEl.textContent = ds.periodText;
    } else {
      // The inline card shows its empty state: the new period has no flows
      detail.data = { nodes: [], links: [] };
    }

    document
      .getElementById("cashflowSankeyChartFullscreen")
      ?.dispatchEvent(new CustomEvent("sankey:set-datasets", { detail }));

    const overlayToggle = document.getElementById("cashflow_show_subcategories_dialog");
    if (overlayToggle) overlayToggle.checked = checked;
  }
}
