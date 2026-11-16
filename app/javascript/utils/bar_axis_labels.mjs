// Which month labels a bar chart's x axis can show without them running into each
// other. A label is "Jan 2026"; when a whole one does not fit the space of one bar
// group, the month alone ("Jan") is shown, and when that does not fit either, every
// n-th one. charWidth: an estimate of one character at the axis font size.
export function barAxisLabels(labels, step, { charWidth = 6.5, gap = 8 } = {}) {
  const width = (text) => text.length * charWidth + gap;
  const longest = Math.max(0, ...labels.map((label) => width(label)));

  if (step >= longest) return labels.map((label) => label);

  const short = labels.map((label) => label.split(" ")[0]);
  const shortest = Math.max(0, ...short.map((label) => width(label)));
  const every = Math.max(1, Math.ceil(shortest / Math.max(step, 1)));

  return short.map((label, index) => (index % every === 0 ? label : ""));
}

// Whether the value labels above the bars fit: each sits over a bar of barWidth
export function barValueLabelsFit(values, barWidth, { charWidth = 6 } = {}) {
  return values.every((text) => text.length * charWidth <= barWidth + 4);
}
