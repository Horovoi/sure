import TimeSeriesChartController from "controllers/time_series_chart_controller";

// Net worth chart on the Reports page. It draws like the time series chart and
// adds each account group's balance at the hovered month to the tooltip, under
// an assets heading and a liabilities heading with their totals.
export default class extends TimeSeriesChartController {
  static values = {
    assetsLabel: { type: String, default: "Assets" },
    liabilitiesLabel: { type: String, default: "Liabilities" },
  };

  _normalizeDataPoints() {
    super._normalizeDataPoints();

    const rawValues = this.dataValue.values || [];
    this._normalDataPoints = this._normalDataPoints.map((point, i) => ({
      ...point,
      assets: rawValues[i]?.assets,
      liabilities: rawValues[i]?.liabilities,
      groups: rawValues[i]?.groups || [],
    }));
  }

  _tooltipTemplate(datum) {
    return `${super._tooltipTemplate(datum)}${this._breakdownTemplate(datum)}`;
  }

  _breakdownTemplate(datum) {
    const groups = datum.groups || [];
    const sections = [
      this._sectionTemplate(
        this.assetsLabelValue,
        datum.assets,
        groups.filter((group) => group.classification === "asset"),
      ),
      this._sectionTemplate(
        this.liabilitiesLabelValue,
        datum.liabilities,
        groups.filter((group) => group.classification === "liability"),
      ),
    ].join("");

    if (!sections) return "";

    return `<div class="mt-2 pt-2 border-t border-secondary space-y-2" data-testid="net-worth-breakdown">${sections}</div>`;
  }

  _sectionTemplate(label, total, groups) {
    if (groups.length === 0) return "";

    const rows = groups
      .map(
        (group) => `
          <div class="flex items-center justify-between gap-4">
            <div class="flex items-center gap-1.5 text-secondary">
              <span class="w-2 h-2 rounded-full shrink-0" style="background-color: ${this._escape(group.color)};"></span>
              ${this._escape(group.name)}
            </div>
            <span class="text-primary tabular-nums privacy-sensitive">${this._escape(this._extractFormattedValue(group.value))}</span>
          </div>
        `,
      )
      .join("");

    return `
      <div class="space-y-1 text-xs">
        <div class="flex items-center justify-between gap-4 font-medium">
          <span class="text-secondary">${this._escape(label)}</span>
          <span class="text-primary tabular-nums privacy-sensitive">${this._escape(this._extractFormattedValue(total))}</span>
        </div>
        ${rows}
      </div>
    `;
  }

  _escape(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }
}
