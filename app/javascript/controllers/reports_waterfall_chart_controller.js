import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_AXIS_LABEL, appendGuideLine, appendLevelLine } from "utils/chart_grid";
import { CHART_TOOLTIP_CLASSES, CHART_TOOLTIP_CONTEXT_CLASSES, CHART_TOOLTIP_VALUE_CLASSES } from "utils/chart_tooltip";
import { formatMoney, formatMoneyCompact } from "utils/format_money";

// Draws a vertical waterfall chart for net worth breakdown
// Assets stack UP (green), liabilities subtract DOWN (red), final bar shows net worth total from 0
export default class extends Controller {
  static values = {
    assets: { type: Array, default: [] },
    liabilities: { type: Array, default: [] },
    netWorth: { type: Number, default: 0 },
    // Money#format_options of the family currency: labels read "17.9K ₴" like
    // the dashboard charts, the tooltip the full amount
    moneyFormat: { type: Object, default: {} },
    netWorthLabel: { type: String, default: "Net Worth" },
  };

  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    d3.select(this.element).selectAll("svg, .waterfall-tooltip").remove();
  }

  _install() {
    const assets = this.assetsValue;
    const liabilities = this.liabilitiesValue;
    if (assets.length === 0 && liabilities.length === 0) return;

    const containerWidth = this.element.clientWidth;
    if (containerWidth < 50) return;

    const netWorth = this.netWorthValue;
    const netWorthLabel = this.netWorthLabelValue;

    // Build waterfall data: each bar has start/end values
    const bars = [];
    let runningTotal = 0;

    // Assets: positive value → UP (green), negative value → DOWN (red)
    assets.forEach((g) => {
      const delta = g.value;
      bars.push({
        name: g.name,
        start: runningTotal,
        end: runningTotal + delta,
        value: Math.abs(delta),
        type: delta >= 0 ? "asset" : "negative_asset",
      });
      runningTotal += delta;
    });

    // Liabilities: positive value → DOWN (red, you owe), negative value → UP (green, overpaid)
    liabilities.forEach((g) => {
      const delta = -g.value; // flip: positive liability = subtract from net worth
      bars.push({
        name: g.name,
        start: runningTotal,
        end: runningTotal + delta,
        value: Math.abs(delta),
        type: delta <= 0 ? "liability" : "negative_liability",
      });
      runningTotal += delta;
    });

    // Final "Net Worth" total bar from 0 to netWorth
    bars.push({
      name: netWorthLabel,
      start: 0,
      end: netWorth,
      value: Math.abs(netWorth),
      type: "total",
    });

    // Dimensions
    const itemCount = bars.length;
    const margin = { top: 16, right: 16, bottom: 60, left: 60 };
    const innerHeight = 280;
    const width = containerWidth;
    const innerWidth = width - margin.left - margin.right;
    const height = innerHeight + margin.top + margin.bottom;

    // Scales
    const xScale = d3
      .scaleBand()
      .domain(bars.map((d) => d.name))
      .range([0, innerWidth])
      .padding(0.3);

    const allValues = bars.flatMap((d) => [d.start, d.end]);
    allValues.push(0); // always include zero baseline
    const yMin = d3.min(allValues);
    const yMax = d3.max(allValues);

    const yScale = d3
      .scaleLinear()
      .domain([yMin, yMax])
      .nice()
      .range([innerHeight, 0]);

    // SVG
    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("class", "overflow-visible");

    const g = svg
      .append("g")
      .attr("transform", `translate(${margin.left}, ${margin.top})`);

    // Tooltip
    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `waterfall-tooltip ${CHART_TOOLTIP_CLASSES} whitespace-nowrap`)
      .style("opacity", 0);

    // Level lines under the bars, then the stronger zero baseline
    const ticks = yScale.ticks(5);
    const grid = g.append("g").attr("class", "grid");
    ticks
      .filter((tick) => tick !== 0)
      .forEach((tick) => appendLevelLine(grid, { x1: 0, x2: innerWidth, y: yScale(tick) }));
    appendLevelLine(g, { x1: 0, x2: innerWidth, y: yScale(0), strong: true });

    // Separator before the total bar
    if (bars.length > 1) {
      const totalIdx = bars.length - 1;
      const separatorX =
        xScale(bars[totalIdx].name) - xScale.step() * xScale.padding() * 0.5;
      appendGuideLine(g, { x1: separatorX, x2: separatorX, y1: 0, y2: innerHeight, reference: true });
    }

    // Draw bars
    bars.forEach((bar, i) => {
      const x = xScale(bar.name);
      const barWidth = xScale.bandwidth();
      const yTop = Math.min(yScale(bar.start), yScale(bar.end));
      const yBottom = Math.max(yScale(bar.start), yScale(bar.end));
      const barHeight = Math.max(yBottom - yTop, 3);
      // bar.value is a magnitude: liabilities subtract, and the total carries net worth's sign
      const isSubtraction = bar.type === "liability" || bar.type === "negative_asset";
      const signedValue = (bar.type === "total" ? netWorth < 0 : isSubtraction) ? -bar.value : bar.value;

      let fillColor;
      if (bar.type === "asset" || bar.type === "negative_liability") {
        fillColor = "var(--color-success)";
      } else if (bar.type === "liability" || bar.type === "negative_asset") {
        fillColor = "var(--color-destructive)";
      } else {
        fillColor =
          netWorth >= 0 ? "var(--color-success)" : "var(--color-destructive)";
      }

      // The same 0.8 as the income and expense bars of the trends chart; the
      // total stays a step lighter so it reads as the sum, not one more group
      const fillOpacity = bar.type === "total" ? 0.7 : 0.8;

      g.append("rect")
        .attr("x", x)
        .attr("y", yTop)
        .attr("width", barWidth)
        .attr("height", barHeight)
        .attr("rx", 3)
        .attr("fill", fillColor)
        .attr("opacity", fillOpacity)
        .style("cursor", "default")
        .on("mouseover", () => {
          tooltip
            .style("opacity", 1)
            .html(
              `<div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${this._escape(bar.name)}</div><div class="${CHART_TOOLTIP_VALUE_CLASSES}">${this._escape(this._formatFull(signedValue))}</div>`
            );
        })
        .on("mousemove", (event) => {
          const rect = this.element.getBoundingClientRect();
          tooltip
            .style("left", `${event.clientX - rect.left + 12}px`)
            .style("top", `${event.clientY - rect.top - 10}px`);
        })
        .on("mouseout", () => {
          tooltip.style("opacity", 0);
        });

      // Value label
      const labelValue = this._formatNumber(signedValue);

      const labelFitsInside = barHeight > 24;
      const labelY = labelFitsInside
        ? yTop + barHeight / 2
        : bar.end >= bar.start
          ? yTop - 6
          : yBottom + 14;

      g.append("text")
        .attr("x", x + barWidth / 2)
        .attr("y", labelY)
        .attr("dy", labelFitsInside ? "0.35em" : 0)
        .attr("text-anchor", "middle")
        .attr("class", "text-xs font-medium privacy-sensitive")
        .style("fill", labelFitsInside ? "white" : fillColor)
        .text(labelValue);

      // Step connector from this bar's end to the next bar's start: a
      // reference line, so it does not read as a level when it runs near one
      if (i < bars.length - 2) {
        // skip last component and don't connect to total
        const nextBar = bars[i + 1];
        appendLevelLine(g, { x1: x + barWidth, x2: xScale(nextBar.name), y: yScale(bar.end), reference: true });
      }
    });

    // X-axis labels
    const shouldRotate = itemCount > 4;
    bars.forEach((bar) => {
      const x = xScale(bar.name) + xScale.bandwidth() / 2;
      const label = g
        .append("text")
        .attr("x", x)
        .attr("y", innerHeight + 16)
        .attr("text-anchor", shouldRotate ? "end" : "middle")
        .attr("class", CHART_AXIS_LABEL)
        .text(bar.name);

      if (shouldRotate) {
        label.attr(
          "transform",
          `rotate(-30, ${x}, ${innerHeight + 16})`
        );
      }
    });

    // Y-axis labels (their level lines are drawn under the bars)
    ticks.forEach((tick) => {
      g.append("text")
        .attr("x", -8)
        .attr("y", yScale(tick))
        .attr("dy", "0.35em")
        .attr("text-anchor", "end")
        .attr("class", `${CHART_AXIS_LABEL} privacy-sensitive`)
        .text(this._formatNumber(tick));
    });
  }

  _escape(text) {
    const div = document.createElement("div");
    div.textContent = text ?? "";
    return div.innerHTML;
  }

  _formatNumber(num) {
    return formatMoneyCompact(num, this.moneyFormatValue);
  }

  _formatFull(num) {
    return formatMoney(num, this.moneyFormatValue.precision ?? 2, this.moneyFormatValue);
  }
}
