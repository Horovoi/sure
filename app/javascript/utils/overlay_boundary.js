// Where a DS--menu or DS--popover panel may sit: inside the window with an
// 8px margin, and for a trigger in the page's content column (#main-content)
// inside that column too, so a panel never spills over a sidebar or, on a
// phone, over the top bar. A trigger in a dialog or in the navigation keeps
// the whole window.
export const OVERLAY_MARGIN = 8;

// Below lg a panel spans the window (with the px-2 gutter of its wrapper).
export const FULL_WIDTH_QUERY = "(max-width: 1023.98px)";

export function overlayBoundary(trigger) {
  let left = 0;
  let top = 0;
  let right = window.innerWidth;
  let bottom = window.innerHeight;

  const column = document.getElementById("main-content");
  if (column && column.contains(trigger) && !trigger.closest("dialog")) {
    const rect = column.getBoundingClientRect();
    left = Math.max(left, rect.left);
    top = Math.max(top, rect.top);
    right = Math.min(right, rect.right);
    bottom = Math.min(bottom, rect.bottom);
  }

  return { x: left, y: top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
}

// flip and shift options that keep a panel inside overlayBoundary. crossAxis:
// a panel taller than the room above or below its trigger (the transactions
// filter on a phone) is kept inside, not cut at the top.
export function overlayMiddlewareOptions(trigger) {
  const boundary = overlayBoundary(trigger);
  return {
    flip: { padding: OVERLAY_MARGIN, boundary },
    shift: { padding: OVERLAY_MARGIN, boundary, crossAxis: true },
  };
}
