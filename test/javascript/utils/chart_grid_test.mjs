import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CHART_GRID_LINE,
  CHART_ZERO_LINE,
  appendGuideLine,
  appendLevelLine,
  crispCoordinate,
} from "../../../app/javascript/utils/chart_grid.mjs";

// A stand-in for a d3 selection: records what the helper appends and sets
function fakeParent() {
  const appended = [];
  return {
    appended,
    append(tag) {
      const node = { tag, attrs: {} };
      appended.push(node);
      const selection = {
        attr(name, value) {
          node.attrs[name] = value;
          return selection;
        },
      };
      return selection;
    },
  };
}

test("a coordinate lands in the middle of a pixel row", () => {
  assert.equal(crispCoordinate(10), 10.5);
  assert.equal(crispCoordinate(10.2), 10.5);
  assert.equal(crispCoordinate(10.9), 10.5);
  assert.equal(crispCoordinate(11.1), 11.5);
  assert.equal(crispCoordinate(0), 0.5);
});

test("a level line is a grid line at a crisp height across the plot", () => {
  const parent = fakeParent();
  appendLevelLine(parent, { x1: 0, x2: 300, y: 42.3 });

  assert.deepEqual(parent.appended, [
    { tag: "line", attrs: { class: CHART_GRID_LINE, x1: 0, x2: 300, y1: 42.5, y2: 42.5 } },
  ]);
});

test("the strong line is the zero line class, with extra classes kept", () => {
  const parent = fakeParent();
  appendLevelLine(parent, { x1: 0, x2: 300, y: 80, strong: true, className: "zero-line" });

  assert.equal(parent.appended[0].attrs.class, `${CHART_ZERO_LINE} zero-line`);
});

test("a vertical guide is crisp on x and keeps its length", () => {
  const parent = fakeParent();
  appendGuideLine(parent, { x1: 120.7, x2: 120.7, y1: 28, y2: 212 });

  assert.deepEqual(parent.appended[0].attrs, { class: CHART_GRID_LINE, x1: 120.5, x2: 120.5, y1: 28, y2: 212 });
});
