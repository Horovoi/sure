// The level lines and axis labels of every D3 chart share one look: the strokes,
// dashes and type are the .chart-grid-line, .chart-zero-line,
// .chart-reference-line, .chart-tick-mark and .chart-axis-label classes in
// sure-design-system.css, coloured by theme tokens. Charts put these classes on
// and do not set strokes, opacities or font sizes.

export const CHART_GRID_LINE = "chart-grid-line";
export const CHART_ZERO_LINE = "chart-zero-line";
export const CHART_REFERENCE_LINE = "chart-reference-line";
export const CHART_TICK_MARK = "chart-tick-mark";
export const CHART_AXIS_LABEL = "chart-axis-label";
export const CHART_LABEL_HALO = "chart-label-halo";
export const CHART_LABEL_PLATE = "chart-label-plate";

// The axis label font size in px, for layout math (label collisions, gutters).
// Keep it the same as .chart-axis-label.
export const CHART_AXIS_LABEL_SIZE = 12;

// A 1px line at a whole coordinate falls between two pixel rows and is drawn as
// two half-strength rows, so one chart's lines looked softer than another's at
// the same colour. The middle of a pixel row draws it sharp.
export function crispCoordinate(value) {
  return Math.round(value - 0.5) + 0.5;
}

// Appends a straight guide to `parent` (a d3 selection): horizontal when y1 and
// y2 are equal (a level line), vertical when x1 and x2 are (a marker such as
// today). A plain guide is a dashed level line; `strong` draws the solid zero
// line (a bar chart's baseline too); `reference` draws a reference that is not a
// level, such as a goal target or the today marker. Extra classes go in
// `className`.
export function appendGuideLine(parent, { x1, x2, y1, y2, strong = false, reference = false, className = "" }) {
  const horizontal = y1 === y2;
  const vertical = x1 === x2;
  const kind = reference ? CHART_REFERENCE_LINE : strong ? CHART_ZERO_LINE : CHART_GRID_LINE;
  const classes = [kind, className].filter(Boolean).join(" ");

  return parent
    .append("line")
    .attr("class", classes)
    .attr("x1", vertical ? crispCoordinate(x1) : x1)
    .attr("x2", vertical ? crispCoordinate(x2) : x2)
    .attr("y1", horizontal ? crispCoordinate(y1) : y1)
    .attr("y2", horizontal ? crispCoordinate(y2) : y2);
}

// A level line across [x1, x2] at height y
export function appendLevelLine(parent, { x1, x2, y, strong = false, reference = false, className = "" }) {
  return appendGuideLine(parent, { x1, x2, y1: y, y2: y, strong, reference, className });
}

// Gives the text of a d3-axis selection (or any text selection) the axis label
// look, keeping the classes in `extra` (for example privacy-sensitive)
export function styleAxisLabels(texts, extra = "") {
  return texts
    .attr("class", [CHART_AXIS_LABEL, extra].filter(Boolean).join(" "))
    .attr("font-size", null)
    .attr("fill", null)
    .style("font-size", null)
    .style("font-weight", null)
    .style("fill", null);
}
