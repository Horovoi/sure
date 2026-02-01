import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Draws a vertical waterfall chart for net worth breakdown
// Assets stack UP (green), liabilities subtract DOWN (red), final bar shows net worth total from 0
export default class extends Controller {
  static values = {
    assets: { type: Array, default: [] },
    liabilities: { type: Array, default: [] },
    netWorth: { type: Number, default: 0 },
    currency: { type: String, default: "$" },
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
    const currency = this.currencyValue;
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
      .attr("class", "waterfall-tooltip")
      .style("position", "absolute")
      .style("pointer-events", "none")
      .style("opacity", 0)
      .style("padding", "6px 10px")
      .style("border-radius", "6px")
      .style("font-size", "12px")
      .style("background", "var(--color-tooltip-bg)")
      .style("border", "1px solid var(--color-tooltip-border)")
      .style("box-shadow", "0 2px 8px rgba(0,0,0,0.12)")
      .style("color", "var(--color-text-primary)")
      .style("z-index", "10")
      .style("white-space", "nowrap");

    // Zero baseline
    g.append("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", yScale(0))
      .attr("y2", yScale(0))
      .attr("stroke", "var(--color-text-secondary)")
      .attr("stroke-width", 1)
      .attr("opacity", 0.4);

    // Dashed separator before total bar
    if (bars.length > 1) {
      const totalIdx = bars.length - 1;
      const separatorX =
        xScale(bars[totalIdx].name) - xScale.step() * xScale.padding() * 0.5;
      g.append("line")
        .attr("x1", separatorX)
        .attr("x2", separatorX)
        .attr("y1", 0)
        .attr("y2", innerHeight)
        .attr("stroke", "var(--color-border)")
        .attr("stroke-dasharray", "4,4")
        .attr("stroke-width", 1);
    }

    // Draw bars
    bars.forEach((bar, i) => {
      const x = xScale(bar.name);
      const barWidth = xScale.bandwidth();
      const yTop = Math.min(yScale(bar.start), yScale(bar.end));
      const yBottom = Math.max(yScale(bar.start), yScale(bar.end));
      const barHeight = Math.max(yBottom - yTop, 3);

      let fillColor;
      if (bar.type === "asset" || bar.type === "negative_liability") {
        fillColor = "var(--color-success)";
      } else if (bar.type === "liability" || bar.type === "negative_asset") {
        fillColor = "var(--color-destructive)";
      } else {
        fillColor =
          netWorth >= 0 ? "var(--color-success)" : "var(--color-destructive)";
      }

      const fillOpacity = bar.type === "total" ? 0.7 : 1;

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
          const isSubtraction = bar.type === "liability" || bar.type === "negative_asset";
          const sign = isSubtraction ? "-" : "";
          tooltip
            .style("opacity", 1)
            .html(
              `<strong>${bar.name}</strong><br>${sign}${currency}${this._formatNumber(bar.value)}`
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
      const isSubtraction = bar.type === "liability" || bar.type === "negative_asset";
      const labelValue =
        bar.type === "total"
          ? `${netWorth < 0 ? "-" : ""}${currency}${this._formatNumber(bar.value)}`
          : isSubtraction
            ? `-${currency}${this._formatNumber(bar.value)}`
            : `${currency}${this._formatNumber(bar.value)}`;

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
        .attr("class", "text-xs font-medium")
        .style("fill", labelFitsInside ? "white" : fillColor)
        .text(labelValue);

      // Connector lines (dashed horizontal from bar end to next bar start)
      if (i < bars.length - 2) {
        // skip last component and don't connect to total
        const nextBar = bars[i + 1];
        const connectorY = yScale(bar.end);
        const nextX = xScale(nextBar.name);
        g.append("line")
          .attr("x1", x + barWidth)
          .attr("x2", nextX)
          .attr("y1", connectorY)
          .attr("y2", connectorY)
          .attr("stroke", "var(--color-text-secondary)")
          .attr("stroke-dasharray", "3,3")
          .attr("stroke-width", 1)
          .attr("opacity", 0.5);
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
        .attr("class", "text-xs")
        .style("fill", "var(--color-text-secondary)")
        .text(bar.name);

      if (shouldRotate) {
        label.attr(
          "transform",
          `rotate(-30, ${x}, ${innerHeight + 16})`
        );
      }
    });

    // Y-axis ticks
    const ticks = yScale.ticks(5);
    ticks.forEach((tick) => {
      const y = yScale(tick);
      g.append("text")
        .attr("x", -8)
        .attr("y", y)
        .attr("dy", "0.35em")
        .attr("text-anchor", "end")
        .attr("class", "text-xs")
        .style("fill", "var(--color-text-secondary)")
        .text(`${tick < 0 ? "-" : ""}${currency}${this._formatNumber(Math.abs(tick))}`);

      // Light grid line
      g.append("line")
        .attr("x1", 0)
        .attr("x2", innerWidth)
        .attr("y1", y)
        .attr("y2", y)
        .attr("stroke", "var(--color-border)")
        .attr("stroke-width", 0.5)
        .attr("opacity", 0.3);
    });
  }

  _formatNumber(num) {
    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
    if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
    return num.toFixed(0);
  }
}
