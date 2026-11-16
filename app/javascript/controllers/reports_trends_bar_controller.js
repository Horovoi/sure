import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { barAxisLabels, barValueLabelsFit } from "utils/bar_axis_labels";
import { appendLevelLine, styleAxisLabels } from "utils/chart_grid";
import { formatMoneyCompact } from "utils/format_money";

// Draws a grouped bar chart for monthly income vs expenses
// Connects to data-controller="reports-trends-bar"
export default class extends Controller {
  static values = {
    trends: { type: Array, default: [] },
    incomeLabel: { type: String, default: "Income" },
    expensesLabel: { type: String, default: "Expenses" },
    // Money#format_options of the family currency, so axis and bar labels read
    // "150K ₴" like the dashboard charts
    moneyFormat: { type: Object, default: {} },
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

    // Whole amounts only: a period with no activity has a 0–1 scale, and
    // "0.2 ₴" steps on it say nothing
    const yTicks = y.ticks(5).filter(Number.isInteger);

    // Level lines; the zero line (the bars' baseline) is the stronger one
    const grid = g.append("g").attr("class", "grid");
    yTicks.forEach((tick) =>
      appendLevelLine(grid, { x1: 0, x2: innerWidth, y: y(tick), strong: tick === 0 })
    );

    // Y-axis
    g.append("g")
      .call(
        d3
          .axisLeft(y)
          .tickValues(yTicks)
          .tickFormat((d) => this._formatNumber(d))
      )
      .call((sel) => sel.select(".domain").remove())
      .call((sel) => styleAxisLabels(sel.selectAll("text"), "privacy-sensitive"))
      .call((sel) => sel.selectAll("line").remove());

    // X-axis: whole labels when they fit the bar group, else the month alone, else
    // every n-th month (a year in a narrow column ran into one string)
    const shownLabels = barAxisLabels(
      trends.map((d) => d.month),
      x0.step(),
      { charWidth: 6.5 },
    );
    const labelFor = new Map(trends.map((d, i) => [d.month, shownLabels[i]]));
    g.append("g")
      .attr("transform", `translate(0, ${innerHeight})`)
      .call(d3.axisBottom(x0).tickSize(0).tickFormat((month) => labelFor.get(month)))
      .call((sel) => sel.select(".domain").remove())
      .call((sel) => styleAxisLabels(sel.selectAll("text")).attr("dy", "1em"));

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

    // Value labels above each respective bar, only when they fit over it: the table
    // below the chart has every figure
    const halfBand = x1.bandwidth() / 2;
    const labelSize = trends.length > 8 ? "9px" : "11px";
    const valueTexts = trends.flatMap((d) => [this._formatNumber(d.income), this._formatNumber(d.expenses)]);
    const showValues = barValueLabelsFit(valueTexts, x1.bandwidth(), { charWidth: trends.length > 8 ? 5.5 : 6.5 });

    monthGroups
      .append("text")
      .attr("x", x1("income") + halfBand)
      .attr("y", (d) => y(d.income) - 3)
      .attr("text-anchor", "middle")
      .attr("font-size", labelSize)
      .attr("class", "privacy-sensitive")
      .style("fill", "var(--color-text-secondary)")
      .text((d) => (showValues && d.income > 0 ? this._formatNumber(d.income) : ""));

    monthGroups
      .append("text")
      .attr("x", x1("expenses") + halfBand)
      .attr("y", (d) => y(d.expenses) - 3)
      .attr("text-anchor", "middle")
      .attr("font-size", labelSize)
      .attr("class", "privacy-sensitive")
      .style("fill", "var(--color-text-secondary)")
      .text((d) => (showValues && d.expenses > 0 ? this._formatNumber(d.expenses) : ""));

    // Legend
    const legendG = svg
      .append("g")
      .attr(
        "transform",
        `translate(${margin.left + innerWidth / 2 - 90}, ${height - 4})`
      );

    [
      { label: this.incomeLabelValue, color: "var(--color-success)" },
      { label: this.expensesLabelValue, color: "var(--color-destructive)" },
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
    return formatMoneyCompact(num, this.moneyFormatValue);
  }
}
