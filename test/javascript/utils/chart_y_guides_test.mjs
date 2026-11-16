import assert from "node:assert/strict";
import { test } from "node:test";
import { chartYGuides } from "../../../app/javascript/utils/chart_y_guides.mjs";

test("a series that crosses zero puts its middle guide on zero", () => {
  const guides = chartYGuides(-50450, 33430);

  assert.deepEqual(
    guides.map((g) => [g.key, g.value, g.zero]),
    [
      ["max", 33430, false],
      ["mid", 0, true],
      ["min", -50450, false],
    ],
  );
});

test("a series on one side of zero keeps its middle guide halfway", () => {
  assert.equal(chartYGuides(100, 300)[1].value, 200);
  assert.equal(chartYGuides(-300, -100)[1].value, -200);
  assert.equal(chartYGuides(0, 300)[1].zero, false);
});
