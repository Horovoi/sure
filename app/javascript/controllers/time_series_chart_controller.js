import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

const parseLocalDate = d3.timeParse("%Y-%m-%d");

export default class extends Controller {
  static values = {
    data: Object,
    strokeWidth: { type: Number, default: 2 },
    useLabels: { type: Boolean, default: true },
    useTooltip: { type: Boolean, default: true },
    // Optional enhancements primarily for fullscreen mode
    showYGuides: { type: Boolean, default: false },
    endpointMarkers: { type: Boolean, default: false },
  };

  _d3SvgMemo = null;
  _d3GroupMemo = null;
  _d3Tooltip = null;
  _d3InitialContainerWidth = 0;
  _d3InitialContainerHeight = 0;
  _normalDataPoints = [];
  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._setupResizeObserver();

    // Allow external controllers to update the dataset dynamically (e.g., fullscreen sync)
    this._onSetData = (e) => {
      const { data } = e.detail || {};
      if (data) {
        this.dataValue = data;
        this._reinstall();
      }
    };
    this.element.addEventListener("timeseries:set-data", this._onSetData);
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
    if (this._onSetData) {
      this.element.removeEventListener("timeseries:set-data", this._onSetData);
      this._onSetData = null;
    }
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    this._d3SvgMemo = null;
    this._d3GroupMemo = null;
    this._d3Tooltip = null;
    this._normalDataPoints = [];

    this._d3Container.selectAll("*").remove();
  }

  _install() {
    this._normalizeDataPoints();
    this._rememberInitialContainerSize();
    this._draw();
  }

  _normalizeDataPoints() {
    this._normalDataPoints = (this.dataValue.values || []).map((d) => ({
      date: parseLocalDate(d.date),
      date_formatted: d.date_formatted,
      value: d.value,
      trend: d.trend,
    }));
  }

  _rememberInitialContainerSize() {
    this._d3InitialContainerWidth = this._d3Container.node().clientWidth;
    this._d3InitialContainerHeight = this._d3Container.node().clientHeight;
  }

  _draw() {
    // Guard against invalid dimensions (e.g., when container is collapsed or not yet rendered)
    const minWidth = 50;
    const minHeight = 50;

    if (
      this._d3ContainerWidth < minWidth ||
      this._d3ContainerHeight < minHeight
    ) {
      // Skip rendering if dimensions are invalid
      return;
    }

    if (this._normalDataPoints.length < 2) {
      this._drawEmpty();
    } else {
      this._drawChart();
    }
  }

  _drawEmpty() {
    this._d3Svg.selectAll(".tick").remove();
    this._d3Svg.selectAll(".domain").remove();

    this._drawDashedLineEmptyState();
    this._drawCenteredCircleEmptyState();
  }

  _drawDashedLineEmptyState() {
    this._d3Svg
      .append("line")
      .attr("x1", this._d3InitialContainerWidth / 2)
      .attr("y1", 0)
      .attr("x2", this._d3InitialContainerWidth / 2)
      .attr("y2", this._d3InitialContainerHeight)
      .attr("stroke", "var(--color-gray-300)")
      .attr("stroke-dasharray", "4, 4");
  }

  _drawCenteredCircleEmptyState() {
    this._d3Svg
      .append("circle")
      .attr("cx", this._d3InitialContainerWidth / 2)
      .attr("cy", this._d3InitialContainerHeight / 2)
      .attr("r", 4)
      .attr("class", "fg-subdued")
      .style("fill", "currentColor");
  }

  _drawChart() {
    this._drawTrendline();

    if (this.useLabelsValue) {
      this._drawXAxisLabels();
      this._drawGradientBelowTrendline();
    }

    // Optional, minimal helpers for context in fullscreen view
    if (this.showYGuidesValue) {
      this._drawYGuides();
    }

    if (this.endpointMarkersValue) {
      this._drawEndpointMarkers();
    }

    if (this.useTooltipValue) {
      this._drawTooltip();
      this._trackMouseForShowingTooltip();
    }
  }

  _drawTrendline() {
    this._installTrendlineSplit();

    this._d3Group
      .append("path")
      .datum(this._normalDataPoints)
      .attr("fill", "none")
      .attr("stroke", `url(#${this.element.id}-split-gradient)`)
      .attr("d", this._d3Line)
      .attr("stroke-linejoin", "round")
      .attr("stroke-linecap", "round")
      .attr("stroke-width", this.strokeWidthValue);
  }

  _installTrendlineSplit() {
    const gradient = this._d3Svg
      .append("defs")
      .append("linearGradient")
      .attr("id", `${this.element.id}-split-gradient`)
      .attr("gradientUnits", "userSpaceOnUse")
      .attr("x1", this._d3XScale.range()[0])
      .attr("x2", this._d3XScale.range()[1]);

    // First stop - solid trend color
    gradient
      .append("stop")
      .attr("class", "start-color")
      .attr("offset", "0%")
      .attr("stop-color", this.dataValue.trend.color);

    // Second stop - trend color right before split
    gradient
      .append("stop")
      .attr("class", "split-before")
      .attr("offset", "100%")
      .attr("stop-color", this.dataValue.trend.color);

    // Third stop - gray color right after split
    gradient
      .append("stop")
      .attr("class", "split-after")
      .attr("offset", "100%")
      .attr("stop-color", "var(--color-gray-400)");

    // Fourth stop - solid gray to end
    gradient
      .append("stop")
      .attr("class", "end-color")
      .attr("offset", "100%")
      .attr("stop-color", "var(--color-gray-400)");
  }

  _setTrendlineSplitAt(percent) {
    const position = percent * 100;

    // Update both stops at the split point
    this._d3Svg
      .select(`#${this.element.id}-split-gradient`)
      .select(".split-before")
      .attr("offset", `${position}%`);

    this._d3Svg
      .select(`#${this.element.id}-split-gradient`)
      .select(".split-after")
      .attr("offset", `${position}%`);

    this._d3Svg
      .select(`#${this.element.id}-trendline-gradient-rect`)
      .attr("width", this._d3ContainerWidth * percent);
  }

  _drawXAxisLabels() {
    // Add ticks
    this._d3Group
      .append("g")
      .attr("transform", `translate(0,${this._d3ContainerHeight})`)
      .call(
        d3
          .axisBottom(this._d3XScale)
          .tickValues([
            this._normalDataPoints[0].date,
            this._normalDataPoints[this._normalDataPoints.length - 1].date,
          ])
          .tickSize(0)
          .tickFormat(d3.timeFormat("%b %d, %Y")),
      )
      .select(".domain")
      .remove();

    // Style ticks
    this._d3Group
      .selectAll(".tick text")
      .attr("class", "fg-gray fill-current")
      .style("font-size", "12px")
      .style("font-weight", "500")
      .attr("text-anchor", "middle")
      .attr("dx", (_d, i) => {
        // Dynamic horizontal offset to reduce collisions with endpoint labels/markers
        // Range ~2.5em–4.5em depending on width
        const em = Math.max(2.5, Math.min(4.5, this._d3ContainerWidth / 300));
        return i === 0 ? `${em}em` : `-${em}em`;
      })
      .attr("dy", "0em");
  }

  _drawGradientBelowTrendline() {
    // Define gradient
    const gradient = this._d3Group
      .append("defs")
      .append("linearGradient")
      .attr("id", `${this.element.id}-trendline-gradient`)
      .attr("gradientUnits", "userSpaceOnUse")
      .attr("x1", 0)
      .attr("x2", 0)
      .attr(
        "y1",
        this._d3YScale(d3.max(this._normalDataPoints, this._getDatumValue)),
      )
      .attr("y2", this._d3ContainerHeight);

    gradient
      .append("stop")
      .attr("offset", 0)
      .attr("stop-color", this._trendColor)
      .attr("stop-opacity", 0.06);

    gradient
      .append("stop")
      .attr("offset", 0.5)
      .attr("stop-color", this._trendColor)
      .attr("stop-opacity", 0);

    // Clip path makes gradient start at the trendline
    this._d3Group
      .append("clipPath")
      .attr("id", `${this.element.id}-clip-below-trendline`)
      .append("path")
      .datum(this._normalDataPoints)
      .attr(
        "d",
        d3
          .area()
          .x((d) => this._d3XScale(d.date))
          .y0(this._d3ContainerHeight)
          .y1((d) => this._d3YScale(this._getDatumValue(d))),
      );

    // Apply the gradient + clip path
    this._d3Group
      .append("rect")
      .attr("id", `${this.element.id}-trendline-gradient-rect`)
      .attr("width", this._d3ContainerWidth)
      .attr("height", this._d3ContainerHeight)
      .attr("clip-path", `url(#${this.element.id}-clip-below-trendline)`)
      .style("fill", `url(#${this.element.id}-trendline-gradient)`);
  }

  _drawTooltip() {
    this._d3Tooltip = d3
      .select(`#${this.element.id}`)
      .append("div")
      .attr(
        "class",
        "bg-container text-sm font-sans absolute p-2 border border-secondary rounded-lg pointer-events-none opacity-0 top-0",
      );
  }

  _trackMouseForShowingTooltip() {
    const bisectDate = d3.bisector((d) => d.date).left;

    this._d3Group
      .append("rect")
      .attr("class", "bg-container")
      .attr("width", this._d3ContainerWidth)
      .attr("height", this._d3ContainerHeight)
      .attr("fill", "none")
      .attr("pointer-events", "all")
      .on("mousemove", (event) => {
        const estimatedTooltipWidth = 250;
        const pageWidth = document.body.clientWidth;
        const tooltipX = event.pageX + 10;
        const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
        const adjustedX =
          overflowX > 0 ? event.pageX - overflowX - 20 : tooltipX;

        const [xPos] = d3.pointer(event);
        const x0 = bisectDate(
          this._normalDataPoints,
          this._d3XScale.invert(xPos),
          1,
        );
        const d0 = this._normalDataPoints[x0 - 1];
        const d1 = this._normalDataPoints[x0];
        const d =
          xPos - this._d3XScale(d0.date) > this._d3XScale(d1.date) - xPos
            ? d1
            : d0;
        const xPercent = this._d3XScale(d.date) / this._d3ContainerWidth;

        this._setTrendlineSplitAt(xPercent);

        // Reset (do not touch endpoint markers)
        this._d3Group.selectAll(".data-point-circle").remove();
        this._d3Group.selectAll(".guideline").remove();

        // Guideline
        this._d3Group
          .append("line")
          .attr("class", "guideline fg-subdued")
          .attr("x1", this._d3XScale(d.date))
          .attr("y1", 0)
          .attr("x2", this._d3XScale(d.date))
          .attr("y2", this._d3ContainerHeight)
          .attr("stroke", "currentColor")
          .attr("stroke-dasharray", "4, 4");

        // Big circle
        this._d3Group
          .append("circle")
          .attr("class", "data-point-circle")
          .attr("cx", this._d3XScale(d.date))
          .attr("cy", this._d3YScale(this._getDatumValue(d)))
          .attr("r", 10)
          .attr("fill", this._trendColor)
          .attr("fill-opacity", "0.1")
          .attr("pointer-events", "none");

        // Small circle
        this._d3Group
          .append("circle")
          .attr("class", "data-point-circle")
          .attr("cx", this._d3XScale(d.date))
          .attr("cy", this._d3YScale(this._getDatumValue(d)))
          .attr("r", 5)
          .attr("fill", this._trendColor)
          .attr("pointer-events", "none");

        // Render tooltip
        this._d3Tooltip
          .html(this._tooltipTemplate(d))
          .style("opacity", 1)
          .style("z-index", 999)
          .style("left", `${adjustedX}px`)
          .style("top", `${event.pageY - 10}px`);
      })
      .on("mouseout", (event) => {
        const hoveringOnGuideline =
          event.toElement?.classList.contains("guideline");

        if (!hoveringOnGuideline) {
          this._d3Group.selectAll(".guideline").remove();
          this._d3Group.selectAll(".data-point-circle").remove();
          this._d3Tooltip.style("opacity", 0);
          this._setTrendlineSplitAt(1);
        }
      });
  }

  // Draw subtle horizontal guide lines at min/mid/max values with right-side labels
  _drawYGuides() {
    const values = this._normalDataPoints.map(this._getDatumValue);
    const dataMin = d3.min(values);
    const dataMax = d3.max(values);
    const dataMid = (dataMin + dataMax) / 2;

    const isDark = this._isDarkTheme();
    const lineOpacityStrong = isDark ? 0.08 : 0.15;
    const lineOpacitySoft = isDark ? 0.05 : 0.10;

    const guides = [
      { key: "max", v: dataMax, opacity: lineOpacityStrong },
      { key: "mid", v: dataMid, opacity: lineOpacitySoft },
      { key: "min", v: dataMin, opacity: lineOpacityStrong },
    ];

    const end = this._normalDataPoints[this._normalDataPoints.length - 1];
    const yEnd = this._d3YScale(this._getDatumValue(end));

    guides.forEach((g) => {
      const y = this._d3YScale(g.v);

      // Avoid drawing labels that collide with endpoint labels or x-axis labels
      const nearEnd = Math.abs(y - yEnd) < 16 && (g.key === "min" || g.key === "max");
      const tooCloseToBottom = this._d3ContainerHeight - y < 16; // collides with bottom date label
      const shouldSkipLabel = nearEnd || (g.key === "min" && tooCloseToBottom);

      // Line
      const [rangeStart, rangeEnd] = this._d3XScale.range();
      this._d3Group
        .append("line")
        .attr("class", "y-guide fg-subdued")
        .attr("x1", rangeStart)
        .attr("x2", rangeEnd)
        .attr("y1", y)
        .attr("y2", y)
        .attr("stroke", "currentColor")
        .attr("stroke-opacity", g.opacity)
        .attr("stroke-dasharray", "4,4");

      if (!shouldSkipLabel) {
        // Label (right aligned)
        const endX = this._d3XScale(end.date);
        // Shift slightly left of the end/gradient boundary to avoid being cut
        const labelX = Math.min(this._d3ContainerWidth - 6, endX - 10);
        this._d3Group
          .append("text")
          .attr("class", "fg-gray fill-current")
          .attr("x", Math.max(0, labelX))
          .attr("y", y - 4)
          .attr("text-anchor", "end")
          .style("font-size", "11px")
          .style("font-weight", "500")
          .text(this._formatMoneyLike(g.v));
      }
    });
  }

  // Add start/end markers with value labels near the path extremes
  _drawEndpointMarkers() {
    const first = this._normalDataPoints[0];
    const last = this._normalDataPoints[this._normalDataPoints.length - 1];

    // Skip endpoints entirely when the series is effectively flat (straight line)
    // Use a small relative epsilon to account for floating point rounding
    const values = this._normalDataPoints.map(this._getDatumValue);
    const dataMin = d3.min(values);
    const dataMax = d3.max(values);
    const scale = Math.max(Math.abs(dataMax), Math.abs(dataMin), 1);
    const epsilon = scale * 1e-6; // ~0.0001% of magnitude
    if (Math.abs(dataMax - dataMin) <= epsilon) {
      return;
    }

    const points = [
      { d: first, align: "start" },
      { d: last, align: "end" },
    ];

    points.forEach(({ d, align }) => {
      const cx = this._d3XScale(d.date);
      const cy = this._d3YScale(this._getDatumValue(d));

      // Determine local slope using a neighbor to better place labels and avoid overlaps
      let neighbor;
      if (align === "start") {
        neighbor = this._normalDataPoints[1] || d;
      } else {
        neighbor = this._normalDataPoints[this._normalDataPoints.length - 2] || d;
      }
      const ny = this._d3YScale(this._getDatumValue(neighbor));
      const slopeUp = ny < cy; // smaller y is visually higher
      const isDark = this._isDarkTheme();
      const outlineColor = isDark ? "var(--color-gray-900)" : "var(--color-white)";

      // Outer halo
      this._d3Group
        .append("circle")
        .attr("class", "endpoint-marker")
        .attr("cx", cx)
        .attr("cy", cy)
        .attr("r", 7)
        .attr("fill", this._trendColor)
        // Lighter, theme-aware halo
        .attr("fill-opacity", isDark ? 0.10 : 0.06)
        .attr("pointer-events", "none");

      // Inner dot
      this._d3Group
        .append("circle")
        .attr("class", "endpoint-marker")
        .attr("cx", cx)
        .attr("cy", cy)
        .attr("r", 3.5)
        // Softer, theme-aware dot with subtle outline for contrast on both themes
        .attr("fill", this._trendColor)
        .attr("fill-opacity", isDark ? 0.75 : 0.6)
        .attr("stroke", outlineColor)
        .attr("stroke-width", 1.5)
        .attr("stroke-opacity", 0.9)
        .attr("pointer-events", "none");

      // Value label
      const labelOffsetX = align === "start" ? 12 : -12;
      // Place label opposite to slope to reduce overlap with the line near the endpoint
      const labelOffsetY = slopeUp ? 14 : -14; // if line goes up, put label below; else above
      const anchor = align === "start" ? "start" : "end";

      // Group for label + background
      const g = this._d3Group.append("g").attr("class", "endpoint-marker label");

      const labelText = this._extractFormattedValue(d.value);
      const text = g
        .append("text")
        // Keep label color as-is (theme-provided via text-primary)
        .attr("class", "text-primary fill-current")
        .attr("x", cx + labelOffsetX)
        .attr("y", cy + labelOffsetY)
        .attr("text-anchor", anchor)
        .style("font-size", "12px")
        .style("font-weight", "600")
        .text(labelText);

      // Minimal style: create a soft halo by stroking a cloned text underneath
      try {
        const haloColor = isDark ? "var(--color-gray-900)" : "var(--color-white)";
        g.insert("text", "text")
          .attr("x", cx + labelOffsetX)
          .attr("y", cy + labelOffsetY)
          .attr("text-anchor", anchor)
          .style("font-size", "12px")
          .style("font-weight", "600")
          .text(labelText)
          .attr("fill", "none")
          .attr("stroke", haloColor)
          .attr("stroke-width", 3.5)
          .attr("stroke-linejoin", "round")
          .attr("stroke-opacity", 0.9)
          .style("paint-order", "stroke fill")
          .attr("pointer-events", "none");

        const bbox = text.node().getBBox();

        // Connector line from marker to the nearest edge of the label, to feel "attached" to the chart
        const labelEdgeX = align === "start" ? bbox.x - 6 : bbox.x + bbox.width + 6;
        const labelEdgeY = bbox.y + bbox.height / 2;
        this._d3Group
          .append("line")
          .attr("x1", cx)
          .attr("y1", cy)
          .attr("x2", labelEdgeX)
          .attr("y2", labelEdgeY)
          .attr("stroke", this._trendColor)
          .attr("stroke-opacity", 0.25)
          .attr("stroke-width", 1.5)
          .attr("stroke-linecap", "round")
          .attr("pointer-events", "none");
      } catch (_) {
        // If getBBox fails (e.g., not in DOM yet), skip background
      }
    });
  }

  // Format a numeric value using the Money-like object available in the dataset when possible.
  // If dataset already provides formatted values, it simply returns them; otherwise fallbacks to
  // a compact number format in the user's locale.
  _formatMoneyLike(rawNumber) {
    // Try to infer currency from the last datum, which includes value.current.currency if Money-like
    const sample = this.dataValue?.values?.[this.dataValue.values.length - 1]?.value;
    const currency = typeof sample === "object" && sample?.currency ? sample.currency : undefined;

    try {
      const fmt = new Intl.NumberFormat(undefined, {
        style: currency ? "currency" : "decimal",
        currency: currency || undefined,
        notation: "compact",
        maximumFractionDigits: 2,
      });
      return fmt.format(Number(rawNumber));
    } catch (_) {
      return String(rawNumber);
    }
  }

  _isDarkTheme() {
    const docEl = document.documentElement;
    const pref = docEl.getAttribute("data-theme") || "system";
    if (pref === "dark") return true;
    if (pref === "light") return false;
    return window.matchMedia?.("(prefers-color-scheme: dark)")?.matches;
  }

  _tooltipTemplate(datum) {
    return `
      <div style="margin-bottom: 4px; color: var(--color-gray-500);">
        ${datum.date_formatted}
      </div>
      <div class="flex items-center gap-4">
        <div class="flex items-center gap-2 text-primary">
          <div class="flex items-center justify-center h-4 w-4">
            ${this._getTrendIcon(datum)}
          </div>
          ${this._extractFormattedValue(datum.trend.current)}
        </div>

        ${
          datum.trend.value === 0
            ? `<span class="w-20"></span>`
            : `
          <span style="color: ${datum.trend.color};">
            ${this._extractFormattedValue(datum.trend.value)} (${datum.trend.percent_formatted})
          </span>
        `
        }
      </div>
    `;
  }

  _getTrendIcon(datum) {
    const isIncrease =
      Number(datum.trend.previous.amount) < Number(datum.trend.current.amount);
    const isDecrease =
      Number(datum.trend.previous.amount) > Number(datum.trend.current.amount);

    if (isIncrease) {
      return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${datum.trend.color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-arrow-up-right-icon lucide-arrow-up-right"><path d="M7 7h10v10"/><path d="M7 17 17 7"/></svg>`;
    }

    if (isDecrease) {
      return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${datum.trend.color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-arrow-down-right-icon lucide-arrow-down-right"><path d="m7 7 10 10"/><path d="M17 7v10H7"/></svg>`;
    }

    return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${datum.trend.color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-minus-icon lucide-minus"><path d="M5 12h14"/></svg>`;
  }

  _getDatumValue = (datum) => {
    return this._extractNumericValue(datum.value);
  };

  _extractNumericValue = (numeric) => {
    if (typeof numeric === "object" && "amount" in numeric) {
      return Number(numeric.amount);
    }
    return Number(numeric);
  };

  _extractFormattedValue = (numeric) => {
    if (typeof numeric === "object" && "formatted" in numeric) {
      return numeric.formatted;
    }
    return numeric;
  };

  _createMainSvg() {
    return this._d3Container
      .append("svg")
      .attr("width", this._d3InitialContainerWidth)
      .attr("height", this._d3InitialContainerHeight)
      .attr("viewBox", [
        0,
        0,
        this._d3InitialContainerWidth,
        this._d3InitialContainerHeight,
      ]);
  }

  _createMainGroup() {
    return this._d3Svg
      .append("g")
      .attr("transform", `translate(${this._margin.left},${this._margin.top})`);
  }

  get _d3Svg() {
    if (!this._d3SvgMemo) {
      this._d3SvgMemo = this._createMainSvg();
    }
    return this._d3SvgMemo;
  }

  get _d3Group() {
    if (!this._d3GroupMemo) {
      this._d3GroupMemo = this._createMainGroup();
    }
    return this._d3GroupMemo;
  }

  get _margin() {
    // Provide extra breathing room when labels/markers/guides are enabled
    const withLabels = this.useLabelsValue;
    const withGuides = this.showYGuidesValue;
    const withMarkers = this.endpointMarkersValue;

    const top = withLabels ? (withMarkers ? 28 : 22) : 4;
    const bottom = withLabels ? (withMarkers ? 18 : 14) : 4;
    const right = withGuides || withMarkers ? 12 : 4;
    const left = withLabels ? 6 : 4;

    return { top, right, bottom, left };
  }

  get _d3ContainerWidth() {
    return (
      this._d3InitialContainerWidth - this._margin.left - this._margin.right
    );
  }

  get _d3ContainerHeight() {
    return (
      this._d3InitialContainerHeight - this._margin.top - this._margin.bottom
    );
  }

  get _d3Container() {
    return d3.select(this.element);
  }

  get _trendColor() {
    return this.dataValue.trend.color;
  }

  get _d3Line() {
    return d3
      .line()
      .x((d) => this._d3XScale(d.date))
      .y((d) => this._d3YScale(this._getDatumValue(d)));
  }

  get _d3XScale() {
    return d3
      .scaleTime()
      .rangeRound([this._xPaddingLeft, this._d3ContainerWidth - this._xPaddingRight])
      .domain(d3.extent(this._normalDataPoints, (d) => d.date));
  }

  get _d3YScale() {
    const dataMin = d3.min(this._normalDataPoints, this._getDatumValue);
    const dataMax = d3.max(this._normalDataPoints, this._getDatumValue);

    // Handle edge case where all values are the same
    if (dataMin === dataMax) {
      const padding = dataMax === 0 ? 100 : Math.abs(dataMax) * 0.5;
      return d3
        .scaleLinear()
        .rangeRound([this._d3ContainerHeight, 0])
        .domain([dataMin - padding, dataMax + padding]);
    }

    const dataRange = dataMax - dataMin;
    const avgValue = (dataMax + dataMin) / 2;

    // Calculate relative change as a percentage
    const relativeChange = avgValue !== 0 ? dataRange / Math.abs(avgValue) : 1;

    // Dynamic baseline calculation
    let yMin;
    let yMax;

    // For small relative changes (< 10%), use a tighter scale
    if (relativeChange < 0.1 && dataMin > 0) {
      // Start axis at a percentage below the minimum, not at 0
      const baselinePadding = dataRange * 2; // Show 2x the data range below min
      yMin = Math.max(0, dataMin - baselinePadding);
      yMax = dataMax + dataRange * 0.6; // Slightly more padding above for labels
    } else {
      // For larger changes or when data crosses zero, use more context
      // Always include 0 when data is negative or close to 0
      if (dataMin < 0 || (dataMin >= 0 && dataMin < avgValue * 0.1)) {
        yMin = Math.min(0, dataMin * 1.1);
      } else {
        // Otherwise use dynamic baseline
        yMin = dataMin - dataRange * 0.35;
      }
      yMax = dataMax + dataRange * 0.15;
    }

    // Adjust padding for labels if needed
    if (this.useLabelsValue) {
      // Add more breathing room when endpoint markers or guides are present
      const factor = (this.endpointMarkersValue || this.showYGuidesValue) ? 0.15 : 0.1;
      const extraPadding = (yMax - yMin) * factor;
      yMin -= extraPadding;
      yMax += extraPadding;
    }

    return d3
      .scaleLinear()
      .rangeRound([this._d3ContainerHeight, 0])
      .domain([yMin, yMax]);
  }

  _setupResizeObserver() {
    this._resizeObserver = new ResizeObserver(() => {
      this._reinstall();
    });
    this._resizeObserver.observe(this.element);
  }

  get _xPaddingLeft() {
    // Prevent clipped endpoints and labels; add more when endpoint markers are visible
    const base = Math.max(8, this.strokeWidthValue * 2);
    return this.endpointMarkersValue ? base + 8 : base + 4;
  }

  get _xPaddingRight() {
    // Mirror left padding and reserve extra room for right-hand labels/guides
    return this._xPaddingLeft + (this.showYGuidesValue ? 10 : 6);
  }
}
