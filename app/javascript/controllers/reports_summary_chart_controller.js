import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Draws a small area sparkline inside summary stat cards
// Connects to data-controller="reports-summary-chart"
export default class extends Controller {
  static values = {
    trend: { type: Array, default: [] },
    color: { type: String, default: "var(--color-success)" },
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
    const container = this.element.querySelector(".sparkline-container");
    if (container) container.remove();
  }

  _install() {
    const data = this.trendValue;
    if (!data || data.length < 2) return;

    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    if (width < 30 || height < 20) return;

    const chartHeight = Math.min(height * 0.45, 60);
    const color = this.colorValue;

    const container = document.createElement("div");
    container.className = "sparkline-container";
    container.style.cssText = `position:absolute;bottom:0;left:0;right:0;height:${chartHeight}px;pointer-events:none;opacity:0.2;`;
    this.element.appendChild(container);

    const svg = d3
      .select(container)
      .append("svg")
      .attr("width", width)
      .attr("height", chartHeight)
      .attr("preserveAspectRatio", "none");

    const xScale = d3
      .scaleLinear()
      .domain([0, data.length - 1])
      .range([0, width]);

    const yScale = d3
      .scaleLinear()
      .domain([d3.min(data) * 0.9, d3.max(data) * 1.1])
      .range([chartHeight - 2, 2]);

    // Gradient fill
    const gradientId = `sparkline-grad-${Math.random().toString(36).slice(2, 8)}`;
    const defs = svg.append("defs");
    const gradient = defs
      .append("linearGradient")
      .attr("id", gradientId)
      .attr("x1", "0%")
      .attr("y1", "0%")
      .attr("x2", "0%")
      .attr("y2", "100%");

    gradient.append("stop").attr("offset", "0%").attr("stop-color", color).attr("stop-opacity", 0.6);
    gradient.append("stop").attr("offset", "100%").attr("stop-color", color).attr("stop-opacity", 0);

    // Area
    const area = d3
      .area()
      .x((_, i) => xScale(i))
      .y0(chartHeight)
      .y1((d) => yScale(d))
      .curve(d3.curveMonotoneX);

    svg.append("path").datum(data).attr("d", area).attr("fill", `url(#${gradientId})`);

    // Line
    const line = d3
      .line()
      .x((_, i) => xScale(i))
      .y((d) => yScale(d))
      .curve(d3.curveMonotoneX);

    svg
      .append("path")
      .datum(data)
      .attr("d", line)
      .attr("fill", "none")
      .attr("stroke", color)
      .attr("stroke-width", 1.5);
  }
}
