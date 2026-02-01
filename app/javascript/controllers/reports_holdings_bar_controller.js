import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Draws horizontal bars for investment holdings sorted by value
// Connects to data-controller="reports-holdings-bar"
export default class extends Controller {
  static values = {
    holdings: { type: Array, default: [] },
    currency: { type: String, default: "$" },
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
    d3.select(this.element).selectAll("svg, .holdings-tooltip").remove();
  }

  _install() {
    const holdings = this.holdingsValue;
    if (holdings.length === 0) return;

    const containerWidth = this.element.clientWidth;
    if (containerWidth < 50) return;

    const barHeight = 36;
    const gap = 8;
    const margin = { top: 8, right: 90, bottom: 8, left: 130 };
    const height = holdings.length * (barHeight + gap) + margin.top + margin.bottom;
    const width = containerWidth;
    const innerWidth = width - margin.left - margin.right;

    const maxVal = d3.max(holdings, (d) => d.value) || 1;
    const xScale = d3.scaleLinear().domain([0, maxVal]).range([0, innerWidth]);

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("class", "overflow-visible");

    const g = svg.append("g").attr("transform", `translate(${margin.left}, ${margin.top})`);

    // Tooltip
    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", "holdings-tooltip")
      .style("position", "absolute")
      .style("pointer-events", "none")
      .style("opacity", 0)
      .style("padding", "8px 12px")
      .style("border-radius", "6px")
      .style("font-size", "12px")
      .style("background", "var(--color-tooltip-bg)")
      .style("border", "1px solid var(--color-tooltip-border)")
      .style("box-shadow", "0 2px 8px rgba(0,0,0,0.12)")
      .style("color", "var(--color-text-primary)")
      .style("z-index", "10")
      .style("white-space", "nowrap");

    const currency = this.currencyValue;

    holdings.forEach((holding, i) => {
      const y = i * (barHeight + gap);
      const barWidth = Math.max(xScale(holding.value), 4);
      const returnPct = holding.returnPct || 0;
      const barColor = returnPct >= 0 ? "var(--color-success)" : "var(--color-destructive)";

      // Background bar (track)
      g.append("rect")
        .attr("x", 0)
        .attr("y", y)
        .attr("width", innerWidth)
        .attr("height", barHeight)
        .attr("rx", 6)
        .attr("fill", "var(--color-surface-inset)")
        .attr("opacity", 0.5);

      // Value bar
      g.append("rect")
        .attr("x", 0)
        .attr("y", y)
        .attr("width", barWidth)
        .attr("height", barHeight)
        .attr("rx", 6)
        .attr("fill", barColor)
        .attr("opacity", 0.8)
        .style("cursor", "default")
        .on("mouseover", () => {
          tooltip.style("opacity", 1).html(
            `<strong>${holding.ticker}</strong> ${holding.name}<br>` +
              `Value: ${currency}${this._formatNumber(holding.value)}<br>` +
              `Weight: ${(holding.weight || 0).toFixed(1)}%<br>` +
              `Return: <span style="color:${barColor}">${returnPct >= 0 ? "+" : ""}${returnPct.toFixed(1)}%</span>`
          );
        })
        .on("mousemove", (evt) => {
          const rect = this.element.getBoundingClientRect();
          tooltip
            .style("left", `${evt.clientX - rect.left + 12}px`)
            .style("top", `${evt.clientY - rect.top - 10}px`);
        })
        .on("mouseout", () => tooltip.style("opacity", 0));

      // Return % label at end of bar
      g.append("text")
        .attr("x", barWidth + 6)
        .attr("y", y + barHeight / 2)
        .attr("dy", "0.35em")
        .attr("text-anchor", "start")
        .attr("class", "text-xs font-medium")
        .style("fill", barColor)
        .text(`${returnPct >= 0 ? "+" : ""}${returnPct.toFixed(1)}%`);

      // Y-axis: ticker + name
      g.append("text")
        .attr("x", -8)
        .attr("y", y + barHeight / 2 - 6)
        .attr("dy", "0.35em")
        .attr("text-anchor", "end")
        .attr("class", "text-xs font-semibold")
        .style("fill", "var(--color-text-primary)")
        .text(holding.ticker);

      g.append("text")
        .attr("x", -8)
        .attr("y", y + barHeight / 2 + 7)
        .attr("dy", "0.35em")
        .attr("text-anchor", "end")
        .attr("class", "text-[10px]")
        .style("fill", "var(--color-text-secondary)")
        .text(holding.name.length > 18 ? holding.name.slice(0, 18) + "..." : holding.name);
    });
  }

  _formatNumber(num) {
    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
    if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
    return num.toFixed(2);
  }
}
