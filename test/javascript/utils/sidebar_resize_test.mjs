import { describe, it } from "node:test"
import assert from "node:assert/strict"
import {
  SIDEBAR_ABS_MAX,
  SIDEBAR_DEFAULTS,
  SIDEBAR_MIN_MAIN_WIDTH,
  SIDEBAR_MIN_WIDTH,
  SIDEBAR_NAVBAR_WIDTH,
  clampSidebarWidth,
} from "../../../app/javascript/utils/sidebar_resize.mjs"

describe("clampSidebarWidth", () => {
  const wide = { viewportWidth: 1920, otherWidth: 400 }

  it("keeps a width inside the bounds", () => {
    assert.equal(clampSidebarWidth(360, { ...wide, absMax: SIDEBAR_ABS_MAX.left }), 360)
  })

  it("never goes below the minimum", () => {
    assert.equal(clampSidebarWidth(10, wide), SIDEBAR_MIN_WIDTH)
  })

  it("stops at the per-side maximum", () => {
    assert.equal(clampSidebarWidth(5000, { ...wide, absMax: SIDEBAR_ABS_MAX.right }), SIDEBAR_ABS_MAX.right)
  })

  it("leaves the main column its minimum width", () => {
    const viewportWidth = 1280
    const otherWidth = 320
    const width = clampSidebarWidth(5000, { viewportWidth, otherWidth })
    assert.equal(width, viewportWidth - SIDEBAR_NAVBAR_WIDTH - otherWidth - SIDEBAR_MIN_MAIN_WIDTH)
    assert.equal(viewportWidth - SIDEBAR_NAVBAR_WIDTH - otherWidth - width, SIDEBAR_MIN_MAIN_WIDTH)
  })

  it("pins to the minimum when the window is too small for both", () => {
    assert.equal(clampSidebarWidth(400, { viewportWidth: 1024, otherWidth: 400 }), SIDEBAR_MIN_WIDTH)
  })

  it("rounds to whole pixels", () => {
    assert.equal(clampSidebarWidth(300.6, wide), 301)
  })

  it("defaults sit inside their own bounds", () => {
    for (const side of ["left", "right"]) {
      assert.ok(SIDEBAR_DEFAULTS[side] >= SIDEBAR_MIN_WIDTH)
      assert.ok(SIDEBAR_DEFAULTS[side] <= SIDEBAR_ABS_MAX[side])
    }
  })
})
