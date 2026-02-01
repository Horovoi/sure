import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Draws a grouped bar chart for monthly income vs expenses
// Connects to data-controller="reports-trends-bar"
export default class extends Controller {
  static values = {
    trends: { type: Array, default: [] },
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
    d3.select(this.element).selectAll("svg").remove();
  }

  _install() {
    const trends = this.trendsValue;
    if (trends.length === 0) return;

    const containerWidth = this.element.clientWidth;
    if (containerWidth < 100) return;

    const margin = { top: 32, right: 12, bottom: 44, left: 64 };
    const height = 270;
    const width = containerWidth;
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    // Scales
    const x0 = d3
      .scaleBand()
      .domain(trends.map((d) => d.month))
      .range([0, innerWidth])
      .padding(0.3);

    const x1 = d3
      .scaleBand()
      .domain(["income", "expenses"])
      .range([0, x0.bandwidth()])
      .padding(0.08);

    const maxVal =
      d3.max(trends, (d) => Math.max(d.income, d.expenses)) || 1;
    const y = d3
      .scaleLinear()
      .domain([0, maxVal * 1.15])
      .nice()
      .range([innerHeight, 0]);

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("class", "overflow-visible");

    const g = svg
      .append("g")
      .attr("transform", `translate(${margin.left}, ${margin.top})`);

    // Grid lines
    g.append("g")
      .attr("class", "grid")
      .call(
        d3.axisLeft(y).ticks(5).tickSize(-innerWidth).tickFormat("")
      )
      .call((sel) => sel.select(".domain").remove())
      .call((sel) =>
        sel
          .selectAll("line")
          .attr("stroke", "var(--color-border)")
          .attr("stroke-dasharray", "2,3")
          .attr("opacity", 0.5)
      );

    // Y-axis
    g.append("g")
      .call(
        d3
          .axisLeft(y)
          .ticks(5)
          .tickFormat((d) => this._formatNumber(d))
      )
      .call((sel) => sel.select(".domain").remove())
      .call((sel) =>
        sel
          .selectAll("text")
          .style("fill", "var(--color-text-secondary)")
          .attr("font-size", "13px")
      )
      .call((sel) => sel.selectAll("line").remove());

    // X-axis
    const xAxisFontSize = trends.length > 8 ? "11px" : "13px";
    g.append("g")
      .attr("transform", `translate(0, ${innerHeight})`)
      .call(d3.axisBottom(x0).tickSize(0))
      .call((sel) => sel.select(".domain").remove())
      .call((sel) =>
        sel
          .selectAll("text")
          .style("fill", "var(--color-text-secondary)")
          .attr("font-size", xAxisFontSize)
          .attr("dy", "1em")
      );

    // Bars
    const monthGroups = g
      .selectAll(".month-group")
      .data(trends)
      .enter()
      .append("g")
      .attr("transform", (d) => `translate(${x0(d.month)}, 0)`);

    // Income bars
    monthGroups
      .append("rect")
      .attr("x", x1("income"))
      .attr("y", (d) => y(d.income))
      .attr("width", x1.bandwidth())
      .attr("height", (d) => Math.max(innerHeight - y(d.income), 0))
      .attr("rx", 3)
      .attr("fill", "var(--color-success)")
      .attr("opacity", 0.8);

    // Expense bars
    monthGroups
      .append("rect")
      .attr("x", x1("expenses"))
      .attr("y", (d) => y(d.expenses))
      .attr("width", x1.bandwidth())
      .attr("height", (d) => Math.max(innerHeight - y(d.expenses), 0))
      .attr("rx", 3)
      .attr("fill", "var(--color-destructive)")
      .attr("opacity", 0.8);

    // Value labels above each respective bar
    const halfBand = x1.bandwidth() / 2;
    const labelSize = trends.length > 8 ? "8px" : "11px";

    monthGroups
      .append("text")
      .attr("x", x1("income") + halfBand)
      .attr("y", (d) => y(d.income) - 3)
      .attr("text-anchor", "middle")
      .attr("font-size", labelSize)
      .style("fill", "var(--color-text-secondary)")
      .text((d) => d.income > 0 ? this._formatNumber(d.income) : "");

    monthGroups
      .append("text")
      .attr("x", x1("expenses") + halfBand)
      .attr("y", (d) => y(d.expenses) - 3)
      .attr("text-anchor", "middle")
      .attr("font-size", labelSize)
      .style("fill", "var(--color-text-secondary)")
      .text((d) => d.expenses > 0 ? this._formatNumber(d.expenses) : "");

    // Legend
    const legendG = svg
      .append("g")
      .attr(
        "transform",
        `translate(${margin.left + innerWidth / 2 - 90}, ${height - 4})`
      );

    [
      { label: "Income", color: "var(--color-success)" },
      { label: "Expenses", color: "var(--color-destructive)" },
    ].forEach((item, i) => {
      const lg = legendG
        .append("g")
        .attr("transform", `translate(${i * 110}, 0)`);
      lg.append("rect")
        .attr("width", 12)
        .attr("height", 12)
        .attr("rx", 2)
        .attr("fill", item.color)
        .attr("opacity", 0.8);
      lg.append("text")
        .attr("x", 16)
        .attr("y", 11)
        .attr("font-size", "13px")
        .style("fill", "var(--color-text-secondary)")
        .text(item.label);
    });
  }

  _formatNumber(num) {
    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
    if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
    return num.toFixed(0);
  }
}
