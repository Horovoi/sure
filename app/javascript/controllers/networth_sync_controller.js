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

      // Update fullscreen header period label
      const label = ds.periodLabel;
      const start = ds.periodStart || (data && data.start_date);
      const end = ds.periodEnd || (data && data.end_date);
      const pretty = label || this.formatRange(start, end);
      const headerEl = document.getElementById("netWorthFullscreenPeriod");
      if (headerEl && pretty) headerEl.textContent = pretty;
    }

    if (!data) return;

    // Update fullscreen chart if present
    const chartEl = document.getElementById("netWorthChartFullscreen");
    if (chartEl) {
      chartEl.dispatchEvent(new CustomEvent("timeseries:set-data", { detail: { data } }));
    }
  }

  formatRange(start, end) {
    if (!start || !end) return null;
    try {
      const fmt = new Intl.DateTimeFormat(undefined, {
        month: "short",
        day: "2-digit",
        year: "numeric",
      });
      const s = fmt.format(new Date(start));
      const e = fmt.format(new Date(end));
      return `${s} to ${e}`;
    } catch {
      return `${start} to ${end}`;
    }
  }
}
