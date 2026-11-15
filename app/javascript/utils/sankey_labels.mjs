// Label-collision rule shared by the dashboard's Sankey charts.
// Nodes compete for labels only within their own
// visual column: d3-sankey's justify alignment can place same-depth nodes
// in different columns (sinks flush right), so columns are keyed by x0,
// not depth. Within a column, labels are considered in descending
// node-value order and kept only when they clear the minimum spacing from
// every label already kept. A small node can no longer hide a large
// category's label merely by sitting above it: the prominent node is
// labeled first, and the small neighbor is the one that yields.
//
// On a narrow chart a label can also run across the gap into the next
// column. When the caller passes each label's measured box (keyed by
// node.index), a label yields if it would cover another node's bar, or a
// more prominent label already kept. That includes its own column: the
// tighter spacing of a large graph (and the tall-bar rule) is shorter than a
// two-line label, so the boxes catch the overlap the spacing rule lets by.
export function hiddenSankeyLabels(nodes, { height, minSpacing, labelBoxes }) {
  const hiddenLabels = new Set();
  const isLargeGraph = height > 600;
  const spacing = isLargeGraph ? minSpacing * 0.7 : minSpacing;
  const bars = labelBoxes ? nodes.map(barBox) : [];
  const keptYsByColumn = new Map();
  const keptBoxes = [];

  // One pass in prominence order, so a label rejected for crossing into
  // another column never blocks a smaller neighbour that would fit.
  [...nodes].sort(byProminence).forEach((node) => {
    // Columns are the visual x position assigned by d3-sankey
    const column = Math.round(node.x0);
    const nodeY = (node.y0 + node.y1) / 2;
    const keptYs = keptYsByColumn.get(column) || [];

    // Tall bars in large graphs always earn their label.
    const spaced =
      (isLargeGraph && node.y1 - node.y0 > spacing * 1.5) ||
      keptYs.every((keptY) => Math.abs(nodeY - keptY) >= spacing);

    const box = labelBoxes?.get(node.index);
    const clear =
      !box ||
      !(
        bars.some((bar) => bar.node !== node && overlaps(box, bar)) ||
        keptBoxes.some((kept) => overlaps(box, kept.box))
      );

    if (spaced && clear) {
      keptYsByColumn.set(column, [...keptYs, nodeY]);
      if (box) keptBoxes.push({ box });
    } else {
      hiddenLabels.add(node.index);
    }
  });

  return hiddenLabels;
}

// Most significant nodes claim their labels first; ties fall back to
// vertical position so the rule stays deterministic.
function byProminence(a, b) {
  if (b.value !== a.value) return b.value - a.value;
  return (a.y0 + a.y1) / 2 - (b.y0 + b.y1) / 2;
}

const CLEARANCE = 2;

function overlaps(a, b) {
  return (
    a.x < b.x + b.width + CLEARANCE &&
    b.x < a.x + a.width + CLEARANCE &&
    a.y < b.y + b.height + CLEARANCE &&
    b.y < a.y + a.height + CLEARANCE
  );
}

function barBox(node) {
  return {
    node,
    x: node.x0,
    y: node.y0,
    width: node.x1 - node.x0,
    height: node.y1 - node.y0,
  };
}
