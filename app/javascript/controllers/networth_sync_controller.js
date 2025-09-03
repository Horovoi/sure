import { Controller } from "@hotwired/stimulus";

// Keeps compact and fullscreen Net Worth chart datasets in sync after frame refreshes
export default class extends Controller {
  connect() {
    // When the net worth section re-renders via Turbo Frame, broadcast fresh data to fullscreen
    this.broadcast();
  }

  broadcast() {
    // Read the latest dataset from the compact chart element
    const compactChart = document.getElementById("netWorthChart");
    let data = null;
    if (compactChart) {
      const ds = compactChart.dataset;
      try {
        data = ds.timeSeriesChartDataValue ? JSON.parse(ds.timeSeriesChartDataValue) : null;
      } catch {}
    }

    if (!data) return;

    // Update fullscreen chart if present
    const chartEl = document.getElementById("netWorthChartFullscreen");
    if (chartEl) {
      chartEl.dispatchEvent(new CustomEvent("timeseries:set-data", { detail: { data } }));
    }
  }
}

