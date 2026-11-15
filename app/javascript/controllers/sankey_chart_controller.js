import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { sankey, sankeyCenter } from "d3-sankey";
import { sankeyLabelOnRight } from "utils/sankey_align";
import { hiddenSankeyLabels } from "utils/sankey_labels";
import { withoutSankeySubcategories } from "utils/sankey_subcategories";

// Connects to data-controller="sankey-chart"
//
// The data is one IncomeStatement::Sankey payload with subcategories. With the
// subcategory toggle off, or on a narrow chart, the subcategory column is
// dropped here; a category's value already includes its subcategories, so no
// total changes.
export default class extends Controller {
  static values = {
    data: Object,
    showSubcategories: { type: Boolean, default: false },
    nodeWidth: { type: Number, default: 15 },
    nodePadding: { type: Number, default: 20 },
    currencySymbol: { type: String, default: "$" },
  };

  // Visual constants
  static HOVER_OPACITY = 0.4;
  static HOVER_FILTER = "saturate(1.3) brightness(1.1)";
  static EXTENT_MARGIN = 16;
  // Below this chart width the subcategory column is dropped: five columns
  // leave about 60px between bars, too little for most labels.
  static SUBCATEGORY_MIN_WIDTH = 640;
  static MIN_NODE_PADDING = 4;
  static MAX_PADDING_RATIO = 0.4;
  static CORNER_RADIUS = 8;
  static DEFAULT_COLOR = "#9E9E9E";
  static CSS_VAR_MAP = {
    "var(--color-success)": "#10A861",
    "var(--color-destructive)": "#EC2222",
    "var(--color-gray-400)": "#9E9E9E",
    "var(--color-gray-500)": "#737373",
  };
  static MIN_LABEL_SPACING = 28; // Minimum vertical space needed for labels (2 lines)

  connect() {
    this.connected = true;
    // Each controller instance has a unique id to scope its SVG defs: the
    // inline chart and the fullscreen one are on the same page
    if (!this.element.id) {
      this.element.id = `sankey-${Math.random().toString(36).slice(2, 10)}`;
    }
    this._instanceId = this.element.id;

    this.resizeObserver = new ResizeObserver(() => this.#draw());
    this.resizeObserver.observe(this.#chartElement());
    this.tooltip = null;
    this.#createTooltip();

    // Subcategory toggle, sent to this element by the toggles
    this._onSubcategoryEvent = (e) => {
      const { showSubcategories } = e.detail || {};
      this.setSubcategoryMode(showSubcategories);
    };
    this.element.addEventListener("sankey:set-subcategories", this._onSubcategoryEvent);

    // New data from the inline card (a period change), sent to the fullscreen chart
    this._onDatasetsEvent = (e) => this.setDatasets(e.detail || {});
    this.element.addEventListener("sankey:set-datasets", this._onDatasetsEvent);

    // A Turbo morph refresh (the sync toast's auto-refresh) keeps this element
    // and its controller but can drop the drawing and the tooltip
    this._onMorph = () => this.#restoreAfterMorph();
    document.addEventListener("turbo:morph", this._onMorph);

    this.#draw();

    // Labels are measured to keep them off neighbouring bars; measure again
    // once the page font has replaced the fallback.
    if (document.fonts?.status === "loading") {
      document.fonts.ready.then(() => {
        if (this.connected) this.#draw();
      });
    }
  }

  disconnect() {
    this.connected = false;
    document.removeEventListener("turbo:morph", this._onMorph);
    this.resizeObserver?.disconnect();
    this.tooltip?.remove();
    this.tooltip = null;
    this.element.removeEventListener("sankey:set-subcategories", this._onSubcategoryEvent);
    this.element.removeEventListener("sankey:set-datasets", this._onDatasetsEvent);
  }

  dataValueChanged() {
    if (this.connected) this.#draw();
  }

  showSubcategoriesValueChanged() {
    if (this.connected) this.#draw();
  }

  // Public: switch the subcategory column on or off
  setSubcategoryMode(show) {
    if (typeof show !== "boolean") return;
    this.showSubcategoriesValue = show;
  }

  // Public: replace the data (the period changed) and the mode
  setDatasets({ data, showSubcategories, currencySymbol }) {
    if (typeof currencySymbol === "string" && currencySymbol.length) {
      this.currencySymbolValue = currencySymbol;
    }
    // Stimulus Object values are parsed from JSON on every read, so compare contents
    if (data && JSON.stringify(data) !== JSON.stringify(this.dataValue)) {
      this.dataValue = data;
    }
    this.setSubcategoryMode(showSubcategories);
  }

  #restoreAfterMorph() {
    if (!this.connected) return;

    this.tooltip?.remove();
    this.#createTooltip();
    if (!this.#chartElement().querySelector("svg")) this.#draw();
  }

  #chartElement() {
    return this.element;
  }

  // A container with no size yet (the fullscreen dialog before it opens) gets
  // the same fallback for the filter and the layout; the ResizeObserver
  // redraws once it has one.
  #chartWidth() {
    return this.#chartElement().clientWidth || 600;
  }

  #visibleData(width) {
    const data = this.dataValue || {};
    const subcategories =
      this.showSubcategoriesValue && width >= this.constructor.SUBCATEGORY_MIN_WIDTH;

    return subcategories ? data : withoutSankeySubcategories(data);
  }

  #draw() {
    const width = this.#chartWidth();
    const { nodes = [], links = [] } = this.#visibleData(width) || {};

    const chart = d3.select(this.#chartElement());
    chart.selectAll("svg").remove();
    if (!nodes.length || !links.length) return;

    this.#hideTooltip();
    this.#render(nodes, links, width);
  }

  #render(nodes, links, width) {
    const chartElement = this.#chartElement();
    const height = chartElement.clientHeight || 400;

    const svg = d3
      .select(chartElement)
      .append("svg")
      .attr("width", width)
      .attr("height", height);

    const effectivePadding = this.#calculateNodePadding(nodes.length, height);
    const sankeyData = this.#generateSankeyData(nodes, links, width, height, effectivePadding);

    this.#createGradients(svg, sankeyData.links);

    const linkPaths = this.#drawLinks(svg, sankeyData.links);
    const { nodeGroups, hiddenLabels } = this.#drawNodes(svg, sankeyData.nodes, width, height);

    this.#attachHoverEvents(linkPaths, nodeGroups, sankeyData, hiddenLabels);
    return svg;
  }

  // Dynamic padding prevents padding from dominating when there are many nodes
  #calculateNodePadding(nodeCount, height) {
    const margin = this.constructor.EXTENT_MARGIN;
    const availableHeight = height - margin * 2;
    const maxPaddingTotal = availableHeight * this.constructor.MAX_PADDING_RATIO;
    const gaps = Math.max(nodeCount - 1, 1);
    const dynamicPadding = Math.min(this.nodePaddingValue, Math.floor(maxPaddingTotal / gaps));
    return Math.max(this.constructor.MIN_NODE_PADDING, dynamicPadding);
  }

  #generateSankeyData(nodes, links, width, height, nodePadding) {
    const margin = this.constructor.EXTENT_MARGIN;
    const sankeyGenerator = sankey()
      // Centre alignment: a sink sits at its depth, a source one column before
      // the nearest node it feeds. The default pushes every sink to the last
      // column, which is the subcategories' once a family has any, so a
      // category without subcategories would cross every parent-to-child link.
      .nodeAlign(sankeyCenter)
      .nodeWidth(this.nodeWidthValue)
      .nodePadding(nodePadding)
      .extent([
        [margin, margin],
        [width - margin, height - margin],
      ]);

    // The server sends amounts as decimal strings, so no precision is lost on the way
    return sankeyGenerator({
      nodes: nodes.map((d) => ({ ...d, value: Number(d.value) })),
      links: links.map((d) => ({ ...d, value: Number(d.value) })),
    });
  }

  #createGradients(svg, links) {
    const defs = svg.append("defs");

    links.forEach((link, i) => {
      const gradient = defs
        .append("linearGradient")
        .attr("id", this.#gradientId(link, i))
        .attr("gradientUnits", "userSpaceOnUse")
        .attr("x1", link.source.x1)
        .attr("x2", link.target.x0);

      gradient
        .append("stop")
        .attr("offset", "0%")
        .attr("stop-color", this.#colorWithOpacity(link.source.color));

      gradient
        .append("stop")
        .attr("offset", "100%")
        .attr("stop-color", this.#colorWithOpacity(link.target.color));
    });
  }

  #gradientId(link, index) {
    return `link-gradient-${this._instanceId}-${link.source.index}-${link.target.index}-${index}`;
  }

  #colorWithOpacity(nodeColor, opacity = 0.1) {
    let colorStr = nodeColor || this.constructor.DEFAULT_COLOR;

    // Map CSS variables to hex values for d3 color manipulation
    colorStr = this.constructor.CSS_VAR_MAP[colorStr] || colorStr;

    // Unmapped CSS vars cannot be resolved in SVG gradients, use default hex
    if (colorStr.startsWith("var(--")) return this.constructor.DEFAULT_COLOR;

    const d3Color = d3.color(colorStr);
    return d3Color ? d3Color.copy({ opacity }) : this.constructor.DEFAULT_COLOR;
  }

  #drawLinks(svg, links) {
    return svg
      .append("g")
      .attr("fill", "none")
      .selectAll("path")
      .data(links)
      .join("path")
      .attr("class", "sankey-link")
      .attr("d", (d) =>
        d3.linkHorizontal()({
          source: [d.source.x1, d.y0],
          target: [d.target.x0, d.y1],
        }),
      )
      .attr("stroke", (d, i) => `url(#${this.#gradientId(d, i)})`)
      .attr("stroke-width", (d) => Math.max(1, d.width))
      .style("transition", "opacity 0.3s ease");
  }

  #drawNodes(svg, nodes, width, height) {
    const nodeGroups = svg
      .append("g")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .attr("data-node-id", (d) => d.id)
      .attr("data-node-kind", (d) => d.kind)
      .style("transition", "opacity 0.3s ease");

    nodeGroups
      .append("path")
      .attr("d", (d) => this.#nodePath(d))
      .attr("fill", (d) => d.color || this.constructor.DEFAULT_COLOR)
      .attr("stroke", (d) => (d.color ? "none" : "var(--color-gray-500)"));

    const hiddenLabels = this.#addNodeLabels(svg, nodeGroups, sankeyLabelOnRight(nodes, width), nodes, height);

    return { nodeGroups, hiddenLabels };
  }

  #nodePath(node) {
    const { x0, y0, x1, y1 } = node;
    const height = y1 - y0;
    const radius = Math.max(0, Math.min(this.constructor.CORNER_RADIUS, height / 2));

    const isSourceNode = node.sourceLinks?.length > 0 && !node.targetLinks?.length;
    const isTargetNode = node.targetLinks?.length > 0 && !node.sourceLinks?.length;

    // Too small for rounded corners
    if (height < radius * 2) {
      return this.#rectPath(x0, y0, x1, y1);
    }

    if (isSourceNode) {
      return this.#roundedLeftPath(x0, y0, x1, y1, radius);
    }

    if (isTargetNode) {
      return this.#roundedRightPath(x0, y0, x1, y1, radius);
    }

    return this.#rectPath(x0, y0, x1, y1);
  }

  #rectPath(x0, y0, x1, y1) {
    return `M ${x0},${y0} L ${x1},${y0} L ${x1},${y1} L ${x0},${y1} Z`;
  }

  #roundedLeftPath(x0, y0, x1, y1, r) {
    return `M ${x0 + r},${y0}
            L ${x1},${y0}
            L ${x1},${y1}
            L ${x0 + r},${y1}
            Q ${x0},${y1} ${x0},${y1 - r}
            L ${x0},${y0 + r}
            Q ${x0},${y0} ${x0 + r},${y0} Z`;
  }

  #roundedRightPath(x0, y0, x1, y1, r) {
    return `M ${x0},${y0}
            L ${x1 - r},${y0}
            Q ${x1},${y0} ${x1},${y0 + r}
            L ${x1},${y1 - r}
            Q ${x1},${y1} ${x1 - r},${y1}
            L ${x0},${y1} Z`;
  }

  #addNodeLabels(svg, nodeGroups, labelOnRight, nodes, height) {
    const controller = this;
    const hiddenLabels = hiddenSankeyLabels(nodes, {
      height,
      minSpacing: this.constructor.MIN_LABEL_SPACING,
      labelBoxes: this.#measureLabels(svg, nodes, labelOnRight),
    });

    nodeGroups
      .append("text")
      .attr("class", "text-xs font-medium text-primary fill-current select-none")
      .style("cursor", "default")
      .style("opacity", (d) => (hiddenLabels.has(d.index) ? 0 : 1))
      // A hidden label can sit over another node's bar; it must not take that
      // bar's hovers and clicks, even while hover reveals it.
      .style("pointer-events", (d) => (hiddenLabels.has(d.index) ? "none" : null))
      .style("transition", "opacity 0.2s ease")
      .each(function (d) {
        controller.#writeLabel(d3.select(this), d, labelOnRight);
      });

    return hiddenLabels;
  }

  // Name above amount, beside the bar on the side the label rule picks.
  #writeLabel(textEl, d, labelOnRight) {
    const right = labelOnRight(d);
    const x = right ? d.x1 + 6 : d.x0 - 6;

    textEl
      .attr("x", x)
      .attr("y", (d.y1 + d.y0) / 2)
      .attr("dy", "-0.2em")
      .attr("text-anchor", right ? "start" : "end");

    textEl.selectAll("tspan").remove();
    textEl.append("tspan").text(d.name);
    textEl
      .append("tspan")
      .attr("x", x)
      .attr("dy", "1.2em")
      .attr("class", "font-mono text-secondary")
      .style("font-size", "0.65rem")
      .text(this.#formatCurrency(d.value));
  }

  // Where each label lands at this width, measured with an invisible probe
  // before the real labels are drawn, so the overlap rule can see a label
  // that reaches into the next column.
  #measureLabels(svg, nodes, labelOnRight) {
    const probe = svg
      .append("text")
      .attr("class", "text-xs font-medium select-none")
      .style("visibility", "hidden");

    const boxes = new Map();
    nodes.forEach((d) => {
      this.#writeLabel(probe, d, labelOnRight);
      const { x, y, width, height } = probe.node().getBBox();
      boxes.set(d.index, { x, y, width, height });
    });

    probe.remove();
    return boxes;
  }

  #attachHoverEvents(linkPaths, nodeGroups, sankeyData, hiddenLabels) {
    const applyHover = (targetLinks) => {
      const targetSet = new Set(targetLinks);
      const connectedNodes = new Set(targetLinks.flatMap((l) => [l.source, l.target]));

      linkPaths
        .style("opacity", (d) => (targetSet.has(d) ? 1 : this.constructor.HOVER_OPACITY))
        .style("filter", (d) => (targetSet.has(d) ? this.constructor.HOVER_FILTER : "none"));

      nodeGroups.style("opacity", (d) => (connectedNodes.has(d) ? 1 : this.constructor.HOVER_OPACITY));

      // Show labels for connected nodes (even if normally hidden)
      nodeGroups
        .selectAll("text")
        .style("opacity", (d) =>
          connectedNodes.has(d) ? 1 : hiddenLabels.has(d.index) ? 0 : this.constructor.HOVER_OPACITY,
        );
    };

    const resetHover = () => {
      linkPaths.style("opacity", 1).style("filter", "none");
      nodeGroups.style("opacity", 1);
      // Restore hidden labels to hidden state
      nodeGroups.selectAll("text").style("opacity", (d) => (hiddenLabels.has(d.index) ? 0 : 1));
    };

    const connectedLinks = (d) => sankeyData.links.filter((l) => l.source === d || l.target === d);

    linkPaths
      .on("mouseenter", (event, d) => {
        applyHover([d]);
        // A link is a flow between two named nodes; name both
        this.#showTooltip(event, d.value, d.percentage, `${d.source.name} → ${d.target.name}`);
      })
      .on("mousemove", (event) => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });

    nodeGroups
      .selectAll("path, text")
      .on("mouseenter", (event, d) => {
        applyHover(connectedLinks(d));
        this.#showTooltip(event, d.value, d.percentage, d.name);
      })
      .on("mousemove", (event) => this.#updateTooltipPosition(event))
      .on("mouseleave", () => {
        resetHover();
        this.#hideTooltip();
      });
  }

  // Tooltip methods

  // A modal dialog is in the top layer, so the fullscreen chart's tooltip
  // lives inside the dialog, positioned against the viewport
  #createTooltip() {
    const dialog = this.element.closest("dialog");
    this.tooltip = d3
      .select(dialog || document.body)
      .append("div")
      .attr("class", "bg-gray-700 text-white text-sm p-2 rounded pointer-events-none absolute z-50 top-0")
      .style("opacity", 0)
      .style("pointer-events", "none");
  }

  // Node names are user-named categories; escape anything put into .html()
  #esc(s) {
    return String(s).replace(
      /[&<>"']/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
    );
  }

  #showTooltip(event, value, percentage, title = null) {
    if (!this.tooltip) this.#createTooltip();

    const formattedValue = this.#formatCurrency(value);
    const percentageText = percentage ? `${percentage}%` : "0%";
    const valueLine = `${this.#esc(formattedValue)} (${this.#esc(percentageText)})`;
    const content = title ? `${this.#esc(title)}<br/>${valueLine}` : valueLine;

    this.tooltip.html(content);
    this.#updateTooltipPosition(event);
    this.tooltip.transition().duration(100).style("opacity", 1);
  }

  #updateTooltipPosition(event) {
    if (!this.tooltip) return;

    const isInDialog = !!this.element.closest("dialog");
    const x = isInDialog ? event.clientX : event.pageX;
    const y = isInDialog ? event.clientY : event.pageY;

    this.tooltip
      .style("position", isInDialog ? "fixed" : "absolute")
      .style("left", `${x + 10}px`)
      .style("top", `${y - 10}px`);
  }

  #hideTooltip() {
    this.tooltip?.transition().duration(100).style("opacity", 0);
  }

  #formatCurrency(value) {
    const formatted = Number.parseFloat(value).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    return this.currencySymbolValue + formatted;
  }
}
