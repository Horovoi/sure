import assert from "node:assert/strict";
import { test } from "node:test";
import { barAxisLabels, barValueLabelsFit } from "../../../app/javascript/utils/bar_axis_labels.mjs";

const year = ["Jan 2026", "Feb 2026", "Mar 2026", "Apr 2026", "May 2026", "Jun 2026",
  "Jul 2026", "Aug 2026", "Sep 2026", "Oct 2026", "Nov 2026"];

test("wide bar groups keep the whole month and year", () => {
  assert.deepEqual(barAxisLabels(["Oct 2026", "Nov 2026"], 200), ["Oct 2026", "Nov 2026"]);
});

test("a year in a narrow chart shows the months alone", () => {
  // About 35px a month: "Jan 2026" (60px) would run into "Feb 2026"
  assert.deepEqual(barAxisLabels(year, 35).slice(0, 3), ["Jan", "Feb", "Mar"]);
});

test("a very narrow chart shows every other month", () => {
  assert.deepEqual(barAxisLabels(year, 20).slice(0, 4), ["Jan", "", "Mar", ""]);
});

test("value labels show only when they fit over their bar", () => {
  assert.equal(barValueLabelsFit(["103.1K", "90.0K"], 60), true);
  assert.equal(barValueLabelsFit(["103.1K", "90.0K"], 12), false);
});
