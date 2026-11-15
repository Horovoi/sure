import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Cumulative spending curve of the dashboard Spending widget: the selected budget
// period's running total (green, ending today while the period runs) over the previous
// period's whole curve (grey), on one day-of-period axis. The server sends the axis
// labels (one per axis day, localized) and one point per day.
const CURRENT_COLOR = "var(--color-success)";
const PREVIOUS_COLOR = "var(--color-gray-400)";

export default class extends Controller {
  static values = {
    data: Object,
    currency: { type: String, default: "USD" },
    currentLabel: { type: String, default: "" },
    previousLabel: { type: String, default: "" },
  };

  #resizeObserver = null;
  #tooltip = null;

  connect() {
    this.#install();
    document.addEventListener("turbo:load", this.#reinstall);
    this.#resizeObserver = new ResizeObserver(() => this.#reinstall());
    this.#resizeObserver.observe(this.element);
  }

  disconnect() {
    this.#teardown();
    document.removeEventListener("turbo:load", this.#reinstall);
    this.#resizeObserver?.disconnect();
  }

  dataValueChanged() {
    if (this.#resizeObserver) this.#reinstall();
  }

  #reinstall = () => {
    this.#teardown();
    this.#install();
  };

  #teardown() {
    d3.select(this.element).selectAll("*").remove();
    this.#tooltip = null;
  }

  #install() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    const { days = 30, axis_labels: axisLabels = [], current = [], previous = [] } = this.dataValue || {};

    if (width < 50 || height < 50) return;
    if (current.length === 0 && previous.length === 0) return;

    const values = [...current, ...previous].map((d) => d.value);
    const maxValue = Math.max(0, d3.max(values) ?? 0);
    // A refund early in a period can take the running total below zero
    const minValue = Math.min(0, d3.min(values) ?? 0);
    if (maxValue === 0 && minValue === 0) return;

    // Room on the right for the amount labels; the curves run to the axis
    const margin = { top: 8, right: 56, bottom: 20, left: 4 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height]);

    const group = svg.append("g").attr("transform", `translate(${margin.left},${margin.top})`);

    const x = d3
      .scaleLinear()
      .domain([1, Math.max(days, 2)])
      .range([0, innerWidth]);
    const y = d3
      .scaleLinear()
      .domain([minValue * 1.05, maxValue * 1.05])
      .nice()
      .range([innerHeight, 0]);

    this.#drawGridlines(group, y, innerWidth);
    this.#drawXAxis(group, x, days, innerHeight, axisLabels);

    const line = d3
      .line()
      .x((d) => x(d.day))
      .y((d) => y(d.value))
      .curve(d3.curveMonotoneX);

    // Previous period first, so the selected period draws on top
    if (previous.length > 0) {
      group
        .append("path")
        .datum(previous)
        .attr("data-series", "previous")
        .attr("fill", "none")
        .attr("stroke", PREVIOUS_COLOR)
        .attr("stroke-width", 1.5)
        .attr("stroke-linejoin", "round")
        .attr("stroke-linecap", "round")
        .attr("d", line);
    }

    if (current.length > 0) {
      group
        .append("path")
        .datum(current)
        .attr("data-series", "current")
        .attr("fill", "none")
        .attr("stroke", CURRENT_COLOR)
        .attr("stroke-width", 2)
        .attr("stroke-linejoin", "round")
        .attr("stroke-linecap", "round")
        .attr("d", line);

      // The end dot marks today on a period that still runs
      const last = current[current.length - 1];
      group
        .append("circle")
        .attr("cx", x(last.day))
        .attr("cy", y(last.value))
        .attr("r", 3.5)
        .attr("fill", CURRENT_COLOR);
    }

    this.#installTooltip(group, x, y, current, previous, innerWidth, innerHeight);
  }

  #drawGridlines(group, y, innerWidth) {
    const ticks = y.ticks(4);

    group
      .append("g")
      .selectAll("line")
      .data(ticks)
      .join("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", (d) => y(d))
      .attr("y2", (d) => y(d))
      .attr("stroke", "var(--color-gray-300)")
      .attr("stroke-dasharray", "4, 4")
      .attr("stroke-opacity", 0.6);

    group
      .append("g")
      .attr("transform", `translate(${innerWidth},0)`)
      .call(
        d3
          .axisRight(y)
          .tickValues(ticks)
          .tickSize(0)
          .tickPadding(8)
          .tickFormat((d) => this.#formatCompact(d)),
      )
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", "text-secondary fill-current")
      .style("font-size", "12px")
      .style("font-weight", "500");
  }

  #drawXAxis(group, x, days, innerHeight, axisLabels) {
    const tickDays = [...new Set([1, Math.round((1 + days) / 2), days])];

    group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(
        d3
          .axisBottom(x)
          .tickValues(tickDays)
          .tickSize(0)
          .tickPadding(8)
          .tickFormat((day) => axisLabels[day - 1] ?? String(day)),
      )
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", "text-secondary fill-current")
      .style("font-size", "12px")
      .style("font-weight", "500")
      .attr("text-anchor", (d) => (d === 1 ? "start" : d === days ? "end" : "middle"));
  }

  #installTooltip(group, x, y, current, previous, innerWidth, innerHeight) {
    // Fixed, against the viewport, so no ancestor's overflow clips it
    this.#tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", "chart-tooltip text-sm font-sans fixed pointer-events-none z-50 top-0 left-0")
      .style("opacity", 0);

    const currentByDay = new Map(current.map((d) => [d.day, d]));
    const previousByDay = new Map(previous.map((d) => [d.day, d]));
    const hoverDays = [...new Set([...currentByDay.keys(), ...previousByDay.keys()])].sort((a, b) => a - b);
    const bisectDay = d3.bisector((d) => d).center;

    const clear = () => {
      group.selectAll(".guideline").remove();
      group.selectAll(".data-point-circle").remove();
      this.#tooltip?.style("opacity", 0);
    };

    group
      .append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "none")
      .attr("pointer-events", "all")
      .on("mousemove", (event) => {
        const [xPos] = d3.pointer(event);
        const i = bisectDay(hoverDays, x.invert(xPos));
        const day = hoverDays[Math.max(0, Math.min(i, hoverDays.length - 1))];
        const currentPoint = currentByDay.get(day);
        const previousPoint = previousByDay.get(day);

        group.selectAll(".guideline").remove();
        group.selectAll(".data-point-circle").remove();

        group
          .append("line")
          .attr("class", "guideline text-subdued")
          .attr("x1", x(day))
          .attr("y1", 0)
          .attr("x2", x(day))
          .attr("y2", innerHeight)
          .attr("stroke", "currentColor")
          .attr("stroke-dasharray", "4, 4")
          .attr("pointer-events", "none");

        for (const [point, color] of [
          [currentPoint, CURRENT_COLOR],
          [previousPoint, PREVIOUS_COLOR],
        ]) {
          if (!point) continue;
          group
            .append("circle")
            .attr("class", "data-point-circle")
            .attr("cx", x(day))
            .attr("cy", y(point.value))
            .attr("r", 4)
            .attr("fill", color)
            .attr("pointer-events", "none");
        }

        const estimatedWidth = 240;
        const left =
          event.clientX + 12 + estimatedWidth > window.innerWidth
            ? event.clientX - estimatedWidth - 12
            : event.clientX + 12;

        this.#tooltip
          .html(this.#tooltipTemplate(currentPoint, previousPoint))
          .style("opacity", 1)
          .style("left", `${Math.max(0, left)}px`)
          .style("top", `${event.clientY - 10}px`);
      })
      .on("mouseleave", clear);
  }

  #tooltipTemplate(currentPoint, previousPoint) {
    const row = (point, color, label) => {
      if (!point) return "";
      return `
        <div class="flex items-center gap-1.5 text-primary font-medium tabular-nums">
          <span class="inline-block w-2 h-2 rounded-full" style="background-color: ${color};"></span>
          <span>${this.#esc(point.date_formatted)}</span>
          <span class="text-secondary font-normal">${this.#esc(label)}</span>
          <span>${this.#esc(this.#formatCurrency(point.value))}</span>
        </div>
      `;
    };

    return `
      <div class="space-y-1">
        ${row(currentPoint, CURRENT_COLOR, this.currentLabelValue)}
        ${row(previousPoint, PREVIOUS_COLOR, this.previousLabelValue)}
      </div>
    `;
  }

  // Everything put into .html() is escaped
  #esc(value) {
    return String(value ?? "").replace(
      /[&<>"']/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
    );
  }

  #formatCurrency(value) {
    try {
      return new Intl.NumberFormat(undefined, { style: "currency", currency: this.currencyValue }).format(value);
    } catch {
      return String(value);
    }
  }

  #formatCompact(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        notation: "compact",
        maximumFractionDigits: 1,
      }).format(value);
    } catch {
      return String(value);
    }
  }
}
