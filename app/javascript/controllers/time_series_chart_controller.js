import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { chartYGuides } from "utils/chart_y_guides";
import { CHART_TOOLTIP_CLASSES, CHART_TOOLTIP_CONTEXT_CLASSES, CHART_TOOLTIP_VALUE_CLASSES } from "utils/chart_tooltip";
import { formatMoneyCompact } from "utils/format_money";

const parseLocalDate = d3.timeParse("%Y-%m-%d");
// The tooltip names its day as the axis does: "Nov 4, 2026"
const tooltipDate = d3.timeFormat("%b %-d, %Y");

export default class extends Controller {
  static values = {
    data: Object,
    strokeWidth: { type: Number, default: 2 },
    useLabels: { type: Boolean, default: true },
    useTooltip: { type: Boolean, default: true },
    // Optional enhancements primarily for fullscreen mode
    showYGuides: { type: Boolean, default: false },
    endpointMarkers: { type: Boolean, default: false },
    fullscreen: { type: Boolean, default: false },
    // Drag across the chart to pick a date range. On release the page visits
    // the same URL with the range in the widget's own query params.
    selectable: { type: Boolean, default: false },
    selectPeriodParam: { type: String, default: "period" },
    selectStartParam: { type: String, default: "start_date" },
    selectEndParam: { type: String, default: "end_date" },
    // The Turbo Frame that holds the widget (the dashboard's net_worth_section):
    // the range then loads into that frame, as the widget's period select does,
    // so the dashboard keeps its scroll position instead of reloading at the top.
    selectFrame: { type: String, default: "" },
    // Money#format_options of the series currency (unit, delimiter, separator,
    // format): the guide amounts then read as the server writes them, "33.4K ₴"
    moneyFormat: { type: Object, default: {} },
  };

  _d3SvgMemo = null;
  _d3GroupMemo = null;
  _d3Tooltip = null;
  _d3InitialContainerWidth = 0;
  _d3InitialContainerHeight = 0;
  _normalDataPoints = [];
  _resizeObserver = null;
  _d3DragSelectBrush = null;
  _d3DragSelectGroup = null;
  // d3 only nulls a truly zero-width selection, so 1-3px of jitter on a click
  // still arrives as a real drag. Treat anything this small as a click.
  _dragSelectMinPx = 4;

  // y-axis domain tuning. Both are relative to the data, so the scale is
  // resolution-independent: a chart looks the same on a phone and a 4K
  // display, only pixel density changes.
  _yAxisPadding = 0.12; // breathing room above and below the series
  _yAxisMinRelSpan = 0.015; // smallest movement allowed to fill the chart,
  // as a fraction of the average balance

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstallIfStale);
    // Colors that depend on the theme are baked into SVG attributes, so a
    // theme switch needs a redraw (theme_controller dispatches the event).
    document.documentElement.addEventListener("theme:change", this._reinstall);
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
    document.removeEventListener("turbo:load", this._reinstallIfStale);
    document.documentElement.removeEventListener(
      "theme:change",
      this._reinstall,
    );
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

  // The ResizeObserver reports the size the chart already has once it starts
  // observing, and turbo:load follows the connect of a page visit. Drawing
  // again then replaced the chart, and the drag overlay under the pointer,
  // right after the page showed. Draw again only for a new size or new data,
  // or when a morph took the drawn chart away.
  _reinstallIfStale = () => {
    if (this._drawnState === this._currentState() && this._isDrawn) return;

    this._reinstall();
  };

  _currentState() {
    const container = this._d3Container.node();
    return [
      container.clientWidth,
      container.clientHeight,
      this.element.getAttribute(`data-${this.identifier}-data-value`),
    ].join("|");
  }

  get _isDrawn() {
    return this._d3Container.node().querySelector("svg") !== null;
  }

  _teardown() {
    this._d3SvgMemo = null;
    this._d3GroupMemo = null;
    this._d3Tooltip = null;
    this._normalDataPoints = [];
    this._d3DragSelectBrush = null;
    this._d3DragSelectGroup = null;

    this._d3Container.selectAll("*").remove();
  }

  _install() {
    this._drawnState = this._currentState();
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
    // Guard against unmeasurable dimensions (e.g., when the container is
    // collapsed or not yet rendered). A hidden container measures 0x0, and the
    // ResizeObserver re-installs the chart as soon as layout gives it a real
    // size, so skipping here only ever defers hidden charts. Small-but-real
    // containers like the 32px-wide sidebar sparklines still render.
    if (this._d3ContainerWidth <= 0 || this._d3ContainerHeight <= 0) {
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
    // Draw zero line and split area fill first (behind trendline)
    this._drawZeroLine();
    this._drawSplitAreaFill();

    this._drawTrendline();

    if (this.useLabelsValue) {
      this._drawXAxisLabels();
      this._drawIntermediateTicks();
      this._drawGradientBelowTrendline();
    }

    // Optional, minimal helpers for context in fullscreen view
    if (this.showYGuidesValue) {
      this._drawYGuides();
    }

    if (this.endpointMarkersValue) {
      this._drawEndpointMarkers();
    }

    if (this.showYGuidesValue && this.endpointMarkersValue) {
      this._dropGuideLabelsOnEndLabel();
    }

    if (this.useTooltipValue) {
      this._drawTooltip();
    }

    // Drawn last, so the brush or hover surface sits on top of every mark.
    // A theme:change or resize redraw runs this again, so the brush stays.
    if (this.useTooltipValue || this.selectableValue) {
      this._drawInteractionOverlay();
    }
  }

  // Draw a subtle dashed horizontal line at y=0 when data crosses zero
  _drawZeroLine() {
    const values = this._normalDataPoints.map(this._getDatumValue);
    const dataMin = d3.min(values);
    const dataMax = d3.max(values);

    // Only draw if data actually crosses zero
    if (dataMin >= 0 || dataMax <= 0) return;

    const zeroY = this._d3YScale(0);
    const [rangeStart, rangeEnd] = this._d3XScale.range();
    const isDark = this._isDarkTheme();

    this._d3Group
      .append("line")
      .attr("class", "zero-line fg-subdued")
      .attr("x1", rangeStart)
      .attr("x2", rangeEnd)
      .attr("y1", zeroY)
      .attr("y2", zeroY)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", isDark ? 0.2 : 0.3)
      .attr("stroke-dasharray", "4,4");
  }

  // Draw split area fills: green above zero, red below zero
  _drawSplitAreaFill() {
    const values = this._normalDataPoints.map(this._getDatumValue);
    const dataMin = d3.min(values);
    const dataMax = d3.max(values);

    // Only draw if data actually crosses zero
    if (dataMin >= 0 || dataMax <= 0) return;

    const zeroY = this._d3YScale(0);
    const isDark = this._isDarkTheme();
    const opacity = isDark ? 0.08 : 0.05;

    // Clip path for positive area (above zero line)
    this._d3Group
      .append("clipPath")
      .attr("id", `${this.element.id}-clip-positive`)
      .append("rect")
      .attr("x", 0)
      .attr("y", 0)
      .attr("width", this._d3ContainerWidth)
      .attr("height", zeroY);

    // Positive area fill (green)
    this._d3Group
      .append("path")
      .datum(this._normalDataPoints)
      .attr("clip-path", `url(#${this.element.id}-clip-positive)`)
      .attr("fill", "var(--color-success)")
      .attr("fill-opacity", opacity)
      .attr(
        "d",
        d3
          .area()
          .x((d) => this._d3XScale(d.date))
          .y0(zeroY)
          .y1((d) => this._d3YScale(this._getDatumValue(d))),
      );

    // Clip path for negative area (below zero line)
    this._d3Group
      .append("clipPath")
      .attr("id", `${this.element.id}-clip-negative`)
      .append("rect")
      .attr("x", 0)
      .attr("y", zeroY)
      .attr("width", this._d3ContainerWidth)
      .attr("height", this._d3ContainerHeight - zeroY);

    // Negative area fill (red)
    this._d3Group
      .append("path")
      .datum(this._normalDataPoints)
      .attr("clip-path", `url(#${this.element.id}-clip-negative)`)
      .attr("fill", "var(--color-destructive)")
      .attr("fill-opacity", opacity)
      .attr(
        "d",
        d3
          .area()
          .x((d) => this._d3XScale(d.date))
          .y0(zeroY)
          .y1((d) => this._d3YScale(this._getDatumValue(d))),
      );
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
      // A flat series (a single valuation or an unchanged balance) would
      // otherwise draw a full-width heavy rule across the card. A faint
      // hairline reads as "no change" in light and dark.
      .attr("stroke-width", this._isFlatSeries ? 1 : this.strokeWidthValue)
      .attr("stroke-opacity", this._isFlatSeries ? 0.4 : 1);
  }

  get _isFlatSeries() {
    const min = d3.min(this._normalDataPoints, this._getDatumValue);
    const max = d3.max(this._normalDataPoints, this._getDatumValue);
    return min === max;
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
          // The year only on the ends; the dates between are "%b %-d"
          .tickFormat(d3.timeFormat("%b %-d, %Y")),
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
      // The same baseline as the dates between (_drawIntermediateTicks)
      .attr("y", this._xLabelBaseline)
      .attr("dy", "0em");
  }

  // Draw intermediate tick marks (both modes) and labels (fullscreen only)
  _drawIntermediateTicks() {
    const data = this._normalDataPoints;
    if (data.length < 10) return; // Skip for short datasets

    const isFullscreen = this.fullscreenValue;
    // Only fullscreen labels its ticks; a tick with no date under it is noise
    if (!isFullscreen) return;
    const [rangeStart, rangeEnd] = this._d3XScale.range();
    const width = rangeEnd - rangeStart;

    // Calculate tick count: more for fullscreen, fewer for compact
    const tickCount = isFullscreen
      ? Math.min(5, Math.floor(width / 200))
      : Math.min(4, Math.floor(width / 150));

    if (tickCount < 1) return;

    // Get evenly spaced dates (excluding first/last which are already shown)
    const timeScale = this._d3XScale;
    const ticks = timeScale.ticks(tickCount + 2).slice(1, -1);

    const isDark = this._isDarkTheme();
    const tickOpacity = isDark ? 0.15 : 0.2;

    ticks.forEach((date) => {
      const x = this._d3XScale(date);

      // Skip if too close to edges (within 10% of width)
      if (x < rangeStart + width * 0.1 || x > rangeEnd - width * 0.1) return;

      // Tick mark (both modes)
      this._d3Group
        .append("line")
        .attr("class", "intermediate-tick fg-subdued")
        .attr("x1", x)
        .attr("x2", x)
        .attr("y1", this._d3ContainerHeight)
        .attr("y2", this._d3ContainerHeight + 4)
        .attr("stroke", "currentColor")
        .attr("stroke-opacity", tickOpacity);

      // Label (fullscreen only)
      if (isFullscreen) {
        this._d3Group
          .append("text")
          .attr("class", "fg-gray fill-current intermediate-label")
          .attr("x", x)
          .attr("y", this._d3ContainerHeight + this._xLabelBaseline)
          .attr("text-anchor", "middle")
          // The same size and weight as the start and end dates
          .style("font-size", "12px")
          .style("font-weight", "500")
          .text(this._formatIntermediateDate(date));
      }
    });
  }

  _formatIntermediateDate(date) {
    // One format for every date between the ends, which carry the year
    return d3.timeFormat("%b %-d")(date); // "Jan 5"
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

  // The surface every chart tooltip shares (.chart-tooltip), as the Spending one
  _drawTooltip() {
    this._d3Tooltip = d3
      .select(`#${this.element.id}`)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);
  }

  // The interaction surface is a plain full-size rect on hover-only charts,
  // or a d3-brush overlay on selectable charts. The tooltip handlers bind to
  // whichever is on top, so hover and drag never fight over pointer events.
  _drawInteractionOverlay() {
    if (this.selectableValue) {
      this._drawDragSelectOverlay();
    } else {
      this._drawHoverOverlay();
    }
  }

  _drawHoverOverlay() {
    const rect = this._d3Group
      .append("rect")
      .attr("class", "bg-container")
      .attr("width", this._d3ContainerWidth)
      .attr("height", this._d3ContainerHeight)
      .attr("fill", "none")
      .attr("pointer-events", "all");

    this._bindTooltipHandlers(rect);
  }

  _drawDragSelectOverlay() {
    const brush = d3
      .brushX()
      .extent([
        [0, 0],
        [this._d3ContainerWidth, this._d3ContainerHeight],
      ])
      // By default d3-brush binds touch events and sets touch-action: none on
      // touch devices, which blocks page scroll over a full-width chart.
      // Drag-select is a mouse gesture, so leave touch alone.
      .touchable(false)
      .on("start brush", (event) => this._handleDragSelectMove(event))
      .on("end", (event) => this._handleDragSelectEnd(event));

    const brushGroup = this._d3Group
      .append("g")
      .attr("class", "drag-select-brush")
      .call(brush);

    brushGroup
      .select(".selection")
      .attr("fill", this._trendColor)
      .attr("fill-opacity", 0.12)
      .attr("stroke", this._trendColor)
      .attr("stroke-opacity", 0.5);

    // Hovering before a mousedown still goes through the overlay's own
    // mousemove. Only a drag in progress needs the brush events above.
    if (this.useTooltipValue) {
      this._bindTooltipHandlers(brushGroup.select(".overlay"));
    }

    this._d3DragSelectBrush = brush;
    this._d3DragSelectGroup = brushGroup;
  }

  // While dragging, d3-brush captures mousemove on the window, so the
  // overlay's own mousemove never fires. Drive the tooltip from the brush
  // events instead, so it stays on the data point under the pointer.
  _handleDragSelectMove(event) {
    const sourceEvent = event.sourceEvent;
    if (!sourceEvent || typeof sourceEvent.pageX !== "number") return;

    const [xPos] = d3.pointer(sourceEvent, this._d3Group.node());
    const datum = this._nearestDataPointForPixel(xPos);

    this._renderTooltipAt(datum, sourceEvent.pageX, sourceEvent.pageY);
  }

  _handleDragSelectEnd(event) {
    this._hideTooltip();

    if (!event.selection) return;

    const [x0, x1] = event.selection;

    if (x1 - x0 < this._dragSelectMinPx) {
      this._clearDragSelection();
      return;
    }

    // Snap to the plotted data points (the ones the tooltip showed during the
    // drag), not the raw pixel-to-time value, which can land days away on a
    // wide chart.
    const startDatum = this._nearestDataPointForPixel(x0);
    const endDatum = this._nearestDataPointForPixel(x1);

    // Reject after snapping: a drag can clear the pixel floor and still
    // collapse to one date. A one-value range draws the empty state, which
    // has no brush to drag back out of.
    if (startDatum === endDatum) {
      this._clearDragSelection();
      return;
    }

    this._navigateToDateRange(startDatum.date, endDatum.date);
  }

  _clearDragSelection() {
    this._d3DragSelectGroup?.call(this._d3DragSelectBrush.move, null);
  }

  // Visits the current URL with the range in this chart's own params: the
  // dashboard net worth widget uses net_worth_period/net_worth_start_date/
  // net_worth_end_date, the account chart period/start_date/end_date.
  _navigateToDateRange(startDate, endDate) {
    const formatDate = d3.timeFormat("%Y-%m-%d");
    const url = new URL(window.location.href);

    url.searchParams.set(this.selectPeriodParamValue, "custom");
    url.searchParams.set(this.selectStartParamValue, formatDate(startDate));
    url.searchParams.set(this.selectEndParamValue, formatDate(endDate));

    if (this.selectFrameValue && document.getElementById(this.selectFrameValue)) {
      Turbo.visit(url.toString(), { frame: this.selectFrameValue, action: "advance" });
    } else {
      Turbo.visit(url.toString());
    }
  }

  _nearestDataPointForPixel(xPos) {
    const bisectDate = d3.bisector((d) => d.date).left;
    const clampedX = Math.max(0, Math.min(xPos, this._d3ContainerWidth));
    const x0 = bisectDate(
      this._normalDataPoints,
      this._d3XScale.invert(clampedX),
      1,
    );
    const d0 = this._normalDataPoints[Math.max(x0 - 1, 0)];
    const d1 =
      this._normalDataPoints[Math.min(x0, this._normalDataPoints.length - 1)];

    return clampedX - this._d3XScale(d0.date) >
      this._d3XScale(d1.date) - clampedX
      ? d1
      : d0;
  }

  _bindTooltipHandlers(selection) {
    selection
      .on("mousemove", (event) => {
        const [xPos] = d3.pointer(event, this._d3Group.node());
        const datum = this._nearestDataPointForPixel(xPos);

        this._renderTooltipAt(datum, event.pageX, event.pageY);
      })
      .on("mouseout", (event) => {
        const hoveringOnGuideline =
          event.toElement?.classList.contains("guideline");

        if (!hoveringOnGuideline) {
          this._hideTooltip();
        }
      });
  }

  _renderTooltipAt(datum, pageX, pageY) {
    const estimatedTooltipWidth = 250;
    const pageWidth = document.body.clientWidth;
    const tooltipX = pageX + 10;
    const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
    const adjustedX = overflowX > 0 ? pageX - overflowX - 20 : tooltipX;

    const xPercent = this._d3XScale(datum.date) / this._d3ContainerWidth;

    this._setTrendlineSplitAt(xPercent);

    // Reset (do not touch endpoint markers)
    this._d3Group.selectAll(".data-point-circle").remove();
    this._d3Group.selectAll(".guideline").remove();

    // Guideline. pointer-events none, so it never steals the overlay's
    // mouse events.
    this._d3Group
      .append("line")
      .attr("class", "guideline fg-subdued")
      .attr("x1", this._d3XScale(datum.date))
      .attr("y1", 0)
      .attr("x2", this._d3XScale(datum.date))
      .attr("y2", this._d3ContainerHeight)
      .attr("stroke", "currentColor")
      .attr("stroke-dasharray", "4, 4")
      .attr("pointer-events", "none");

    // Big circle
    this._d3Group
      .append("circle")
      .attr("class", "data-point-circle")
      .attr("cx", this._d3XScale(datum.date))
      .attr("cy", this._d3YScale(this._getDatumValue(datum)))
      .attr("r", 10)
      .attr("fill", this._trendColor)
      .attr("fill-opacity", "0.1")
      .attr("pointer-events", "none");

    // Small circle
    this._d3Group
      .append("circle")
      .attr("class", "data-point-circle")
      .attr("cx", this._d3XScale(datum.date))
      .attr("cy", this._d3YScale(this._getDatumValue(datum)))
      .attr("r", 5)
      .attr("fill", this._trendColor)
      .attr("pointer-events", "none");

    // A selectable chart with use_tooltip=false has no tooltip node, but the
    // brush still drives this method for the guideline and circles.
    this._d3Tooltip
      ?.html(this._tooltipTemplate(datum))
      .style("opacity", 1)
      .style("z-index", 999)
      .style("left", `${adjustedX}px`)
      .style("top", `${pageY - 10}px`);
  }

  _hideTooltip() {
    this._d3Group.selectAll(".guideline").remove();
    this._d3Group.selectAll(".data-point-circle").remove();
    this._d3Tooltip?.style("opacity", 0);
    this._setTrendlineSplitAt(1);
  }

  // Draw subtle horizontal guide lines at min/mid/max values with right-side labels
  _drawYGuides() {
    const values = this._normalDataPoints.map(this._getDatumValue);
    const dataMin = d3.min(values);
    const dataMax = d3.max(values);

    const isDark = this._isDarkTheme();
    // One strength for every guide: each label needs a line you can see under it
    const lineOpacity = isDark ? 0.12 : 0.15;

    // When the series crosses zero, the middle guide is the zero line (drawn by
    // _drawZeroLine), so its label reads 0 and sits on a line that is there
    const guides = chartYGuides(dataMin, dataMax).map((g) => ({ ...g, v: g.value, opacity: lineOpacity }));
    const labelledYs = [];

    const end = this._normalDataPoints[this._normalDataPoints.length - 1];
    const yEnd = this._d3YScale(this._getDatumValue(end));
    // The end value label sits right-aligned in the same column as the guide
    // labels, so any guide label in its band would be drawn on top of it.
    const endLabelY = this.endpointMarkersValue ? this._endpointLabelY("end") : null;

    guides.forEach((g) => {
      const y = this._d3YScale(g.v);

      // Avoid drawing labels that collide with endpoint labels or x-axis labels.
      // A guide label is 11px text with its baseline at y - 4; the end label is
      // 12px text with its baseline at endLabelY.
      const nearEnd = Math.abs(y - yEnd) < 16 && (g.key === "min" || g.key === "max");
      const onEndLabel =
        endLabelY !== null && y - 4 > endLabelY - 12 - 2 && y - 4 - 11 < endLabelY + 3 + 2;
      const tooCloseToBottom = this._d3ContainerHeight - y < 16; // collides with bottom date label
      // Two guide labels closer than a line of text would overlap
      const onOtherLabel = labelledYs.some((other) => Math.abs(other - y) < 14);
      const shouldSkipLabel =
        nearEnd || onEndLabel || onOtherLabel || (g.key === "min" && tooCloseToBottom);

      // Line (the zero line is already drawn)
      const [rangeStart, rangeEnd] = this._d3XScale.range();
      if (!g.zero) {
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
      }

      if (!shouldSkipLabel) {
        labelledYs.push(y);
        // Label (right aligned)
        const endX = this._d3XScale(end.date);
        // Shift slightly left of the end/gradient boundary to avoid being cut
        const labelX = Math.min(this._d3ContainerWidth - 6, endX - 10);
        this._d3Group
          .append("text")
          .attr("class", "fg-gray fill-current privacy-sensitive")
          .attr("x", Math.max(0, labelX))
          .attr("y", y - 4)
          .attr("text-anchor", "end")
          .style("font-size", "11px")
          .style("font-weight", "500")
          .text(this._formatMoneyLike(g.v));
      }
    });
  }

  // Baseline y of the start or end value label. It goes to the side the line
  // does not come from, so it stays off the line next to the marker: below
  // when the neighbouring point is higher, above when it is lower or level.
  _endpointLabelY(align) {
    const points = this._normalDataPoints;
    const d = align === "start" ? points[0] : points[points.length - 1];
    const neighbor = (align === "start" ? points[1] : points[points.length - 2]) || d;
    const cy = this._d3YScale(this._getDatumValue(d));
    const ny = this._d3YScale(this._getDatumValue(neighbor));
    const slopeUp = ny < cy; // smaller y is visually higher
    return cy + (slopeUp ? 14 : -14);
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
      const labelY = this._endpointLabelY(align);
      const anchor = align === "start" ? "start" : "end";

      // Group for label + background
      const g = this._d3Group.append("g").attr("class", "endpoint-marker label privacy-sensitive");

      const labelText = this._extractFormattedValue(d.value);
      const text = g
        .append("text")
        // Keep label color as-is (theme-provided via text-primary)
        .attr("class", "text-primary fill-current")
        .attr("x", cx + labelOffsetX)
        .attr("y", labelY)
        .attr("text-anchor", anchor)
        .style("font-size", "12px")
        .style("font-weight", "600")
        .text(labelText);

      // Minimal style: create a soft halo by stroking a cloned text underneath
      try {
        const haloColor = isDark ? "var(--color-gray-900)" : "var(--color-white)";
        g.insert("text", "text")
          .attr("x", cx + labelOffsetX)
          .attr("y", labelY)
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
    // The server's own format when the page hands it over
    if (this.moneyFormatValue?.unit !== undefined) {
      return formatMoneyCompact(Number(rawNumber), this.moneyFormatValue);
    }

    // Try to infer currency from the last datum, which includes value.current.currency if Money-like
    const sample = this.dataValue?.values?.[this.dataValue.values.length - 1]?.value;
    const currency = typeof sample === "object" && sample?.currency ? sample.currency : undefined;

    try {
      const fmt = new Intl.NumberFormat(undefined, {
        style: currency ? "currency" : "decimal",
        currency: currency || undefined,
        // "₴33.43K", as the amounts around the chart, not "UAH 33.43K"
        currencyDisplay: currency ? "narrowSymbol" : undefined,
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
      <div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${tooltipDate(datum.date)}</div>
      <div class="flex items-center gap-4 tabular-nums">
        <div class="flex items-center gap-2 text-primary">
          <div class="flex items-center justify-center h-4 w-4">
            ${this._getTrendIcon(datum)}
          </div>
          <span class="${CHART_TOOLTIP_VALUE_CLASSES} privacy-sensitive">${this._extractFormattedValue(datum.trend.current)}</span>
        </div>

        ${
          // trend.value is serialized Money ({ amount: "0.0", ... }), so compare
          // its number; an infinite percent (zero base) serializes as null.
          this._extractNumericValue(datum.trend.value) === 0
            ? `<span class="w-20"></span>`
            : `
          <span class="privacy-sensitive" style="color: ${datum.trend.color};">
            ${this._extractFormattedValue(datum.trend.value)}${
              datum.trend.percent === null
                ? ""
                : ` (${datum.trend.percent_formatted})`
            }
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
    const isFullscreen = this.fullscreenValue;

    const top = withLabels ? (withMarkers ? 28 : 22) : 4;
    // Extra bottom space in fullscreen for intermediate date labels
    const bottom = withLabels ? (isFullscreen ? 24 : withMarkers ? 18 : 14) : 4;
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
      .rangeRound(this._xRange)
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

    // Honesty floor: a movement smaller than _yAxisMinRelSpan of the average
    // balance never fills the chart, so trivial noise on a large balance
    // stays flat. Anything larger shows at full amplitude, centered, with the
    // same padding above and below.
    const minSpan = Math.abs(avgValue) * this._yAxisMinRelSpan;
    const effectiveRange = Math.max(dataRange, minSpan);

    const padding = effectiveRange * this._yAxisPadding;
    let yMin = avgValue - effectiveRange / 2 - padding;
    let yMax = avgValue + effectiveRange / 2 + padding;

    // Pull the nearer bound to zero only when the data sits close to zero
    // relative to its own scale, so a balance far from zero (positive or
    // negative) still fills the chart with its movement. A series that
    // crosses zero keeps zero in view on its own.
    if (dataMin >= 0 && dataMin < avgValue * 0.1) {
      yMin = Math.min(0, yMin);
    } else if (dataMax <= 0 && dataMax > avgValue * 0.1) {
      yMax = Math.max(0, yMax);
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
      this._reinstallIfStale();
    });
    this._resizeObserver.observe(this.element);
  }

  // A bare line (a 32px sidebar sparkline) only needs room for its stroke caps:
  // the labelled paddings below are wider than such a chart, and the scale ran
  // backwards.
  get _isSparkline() {
    return !this.useLabelsValue && !this.endpointMarkersValue && !this.showYGuidesValue;
  }

  get _xPaddingLeft() {
    if (this._isSparkline) return this.strokeWidthValue;
    // Prevent clipped endpoints and labels; add more when endpoint markers are visible
    const base = Math.max(8, this.strokeWidthValue * 2);
    return this.endpointMarkersValue ? base + 8 : base + 4;
  }

  get _xPaddingRight() {
    if (this._isSparkline) return this.strokeWidthValue;
    // Mirror left padding and reserve extra room for right-hand labels/guides
    return this._xPaddingLeft + (this.showYGuidesValue ? 10 : 6);
  }

  // The x range inside the paddings, or the whole width when they leave none
  get _xRange() {
    const width = this._d3ContainerWidth;
    const left = this._xPaddingLeft;
    const right = width - this._xPaddingRight;
    return right > left ? [left, right] : [0, Math.max(0, width)];
  }

  // Baseline of every x-axis date (the ends and the ones between), below the
  // plot, measured from its bottom edge: 4px above the bottom of the margin
  get _xLabelBaseline() {
    return Math.max(10, this._margin.bottom - 4);
  }

  // A guide label is right-aligned beside the end marker, in the column of the
  // end value label. Measured once both are drawn, a guide label within 6px of
  // the end label's box, or one level with the end marker and within 20px of
  // it, is dropped. The guide labels are the group's own privacy-sensitive texts;
  // the value labels sit in g.endpoint-marker groups.
  _dropGuideLabelsOnEndLabel() {
    const endLabel = this._d3Group.selectAll("g.endpoint-marker.label text.text-primary").nodes().pop();
    if (!endLabel) return;

    let endBox;
    try {
      endBox = endLabel.getBBox();
    } catch (_) {
      return;
    }

    const last = this._normalDataPoints[this._normalDataPoints.length - 1];
    const markerX = this._d3XScale(last.date);
    const markerY = this._d3YScale(this._getDatumValue(last));
    const markerR = 7; // the outer halo

    const gap = (aStart, aEnd, bStart, bEnd) => Math.max(bStart - aEnd, aStart - bEnd, 0);

    this._d3Group.selectAll(":scope > text.privacy-sensitive").each(function () {
      let box;
      try {
        box = this.getBBox();
      } catch (_) {
        return;
      }

      const nearEndLabel =
        gap(box.x, box.x + box.width, endBox.x, endBox.x + endBox.width) < 6 &&
        gap(box.y, box.y + box.height, endBox.y, endBox.y + endBox.height) < 6;
      const besideMarker =
        gap(box.x, box.x + box.width, markerX - markerR, markerX + markerR) < 20 &&
        gap(box.y, box.y + box.height, markerY - markerR, markerY + markerR) === 0;

      if (nearEndLabel || besideMarker) this.remove();
    });
  }
}
