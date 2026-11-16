// The three horizontal guides of a time series chart: the top, the middle and the
// bottom of the series. When the series crosses zero the middle guide is zero, so
// its label sits on the dashed zero line instead of floating beside it.
export function chartYGuides(min, max) {
  const crossesZero = min < 0 && max > 0;

  return [
    { key: "max", value: max, zero: false },
    { key: "mid", value: crossesZero ? 0 : (min + max) / 2, zero: crossesZero },
    { key: "min", value: min, zero: false },
  ];
}
