import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Draws a treemap for category breakdown (income or expense)
// Connects to data-controller="reports-treemap"
export default class extends Controller {
  static values = {
    categories: { type: Array, default: [] },
    type: { type: String, default: "expense" },
  };

  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    d3.select(this.element).selectAll("svg, .treemap-tooltip").remove();
  }

  _install() {
    const categories = this.categoriesValue;
    if (categories.length === 0) return;

    const containerWidth = this.element.clientWidth;
    if (containerWidth < 50) return;

    const uid = Math.random().toString(36).slice(2, 8);

    const height = 280;
    const width = containerWidth;

    // Build hierarchy
    const root = d3
      .hierarchy({
        children: categories.map((c) => ({
          name: c.name,
          value: c.amount,
          color: c.color || "#94a3b8",
          percentage: c.percentage,
          formattedAmount: c.formattedAmount,
        })),
      })
      .sum((d) => d.value);

    d3.treemap()
      .tile(d3.treemapSquarify)
      .size([width, height])
      .padding(3)
      .round(true)(root);

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height);

    // Tooltip
    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", "treemap-tooltip")
      .style("position", "absolute")
      .style("pointer-events", "none")
      .style("opacity", 0)
      .style("padding", "8px 12px")
      .style("border-radius", "6px")
      .style("font-size", "12px")
      .style("background", "var(--color-tooltip-bg)")
      .style("border", "1px solid var(--color-tooltip-border)")
      .style("box-shadow", "0 2px 8px rgba(0,0,0,0.12)")
      .style("color", "var(--color-text-primary)")
      .style("z-index", "10")
      .style("white-space", "nowrap");

    const leaves = root.leaves();
    const nodes = svg
      .selectAll("g")
      .data(leaves)
      .enter()
      .append("g")
      .attr("transform", (d) => `translate(${d.x0},${d.y0})`)
      .style("pointer-events", "all");

    // ClipPath per tile — prevents text from bleeding outside tile boundaries
    const defs = svg.append("defs");
    leaves.forEach((d, i) => {
      defs
        .append("clipPath")
        .attr("id", `treemap-clip-${uid}-${i}`)
        .append("rect")
        .attr("width", d.x1 - d.x0)
        .attr("height", d.y1 - d.y0)
        .attr("rx", 6);
    });
    nodes.attr("clip-path", (_d, i) => `url(#treemap-clip-${uid}-${i})`);

    // Tile rects
    nodes
      .append("rect")
      .attr("width", (d) => d.x1 - d.x0)
      .attr("height", (d) => d.y1 - d.y0)
      .attr("rx", 6)
      .attr("fill", (d) => d.data.color)
      .attr("opacity", 0.9)
      .style("cursor", "default");

    // Helpers
    const tileW = (d) => d.x1 - d.x0;
    const tileH = (d) => d.y1 - d.y0;

    const truncate = (text, availableWidth, fontSize, tilePad) => {
      const usable = availableWidth - tilePad * 2;
      if (usable <= 0) return "";
      const maxChars = Math.floor(usable / (fontSize * 0.55));
      if (maxChars <= 0) return "";
      const str = String(text);
      if (str.length <= maxChars) return str;
      return maxChars > 3
        ? str.slice(0, maxChars - 1) + "\u2026"
        : str.slice(0, maxChars);
    };

    const abbreviate = (name, maxLen) => {
      const str = String(name).trim();
      if (str.length <= maxLen) return str;
      const words = str.split(/[\s&,/]+/).filter(Boolean);
      if (maxLen >= 2 && words.length >= 2) {
        return (words[0][0] + words[1][0]).toUpperCase();
      }
      return str[0].toUpperCase();
    };

    const styleText = (sel, size, bold) => {
      const px = parseFloat(size);
      const sw = px >= 13 ? 3 : px >= 11 ? 2.5 : px >= 9 ? 2 : 1.5;
      return sel
        .attr("fill", "#fff")
        .attr("stroke", "rgba(0,0,0,0.35)")
        .attr("stroke-width", sw)
        .attr("paint-order", "stroke")
        .attr("pointer-events", "none")
        .attr("font-size", size)
        .attr("font-weight", bold ? "600" : "400");
    };

    // Single-pass tier classification (relaxed thresholds — clipPath prevents overflow)
    const classify = (d) => {
      const w = tileW(d),
        h = tileH(d),
        area = w * h,
        minDim = Math.min(w, h);
      if (w > 70 && h > 48) return "large";
      if (w > 40 && h > 28) return "medium";
      if ((w >= h && w > 20 && h > 14) || (h > w && w > 12 && h > 20))
        return "small";
      if (area >= 80 && minDim >= 8) return "tiny";
      if (area >= 30 && minDim >= 5) return "micro";
      return "none";
    };

    const PAD_DEFAULT = 8;
    const PAD_SMALL = 4;

    // --- Large tiles (w>80, h>54): name + amount + % ---
    const large = nodes.filter((d) => classify(d) === "large");

    styleText(
      large
        .append("text")
        .attr("x", PAD_DEFAULT)
        .attr("y", (d) => tileH(d) / 2 - 12)
        .attr("dy", "0.35em"),
      "13px",
      true
    ).text((d) => truncate(d.data.name, tileW(d), 13, PAD_DEFAULT));

    styleText(
      large
        .append("text")
        .attr("x", PAD_DEFAULT)
        .attr("y", (d) => tileH(d) / 2 + 4)
        .attr("dy", "0.35em"),
      "12px",
      false
    ).text((d) => truncate(d.data.formattedAmount, tileW(d), 12, PAD_DEFAULT));

    styleText(
      large
        .append("text")
        .attr("x", PAD_DEFAULT)
        .attr("y", (d) => tileH(d) / 2 + 19)
        .attr("dy", "0.35em"),
      "11px",
      false
    )
      .attr("fill", "rgba(255,255,255,0.75)")
      .text((d) => `${Number(d.data.percentage).toFixed(1)}%`);

    // --- Medium tiles: name + % (falls back to % if name doesn't fit) ---
    const medium = nodes.filter((d) => classify(d) === "medium");

    styleText(
      medium
        .append("text")
        .attr("x", PAD_DEFAULT)
        .attr("y", (d) => tileH(d) / 2 - 5)
        .attr("dy", "0.35em"),
      "11px",
      true
    ).text((d) => {
      const name = truncate(d.data.name, tileW(d), 11, PAD_DEFAULT);
      return name || `${Number(d.data.percentage).toFixed(1)}%`;
    });

    styleText(
      medium
        .append("text")
        .attr("x", PAD_DEFAULT)
        .attr("y", (d) => tileH(d) / 2 + 10)
        .attr("dy", "0.35em"),
      "10px",
      false
    )
      .attr("fill", "rgba(255,255,255,0.75)")
      .text((d) => {
        const name = truncate(d.data.name, tileW(d), 11, PAD_DEFAULT);
        return name ? `${Number(d.data.percentage).toFixed(1)}%` : "";
      });

    // --- Small tiles: truncated name or % fallback ---
    const small = nodes.filter((d) => classify(d) === "small");

    // Landscape orientation
    const smallLandscape = small.filter((d) => tileW(d) >= tileH(d));
    styleText(
      smallLandscape
        .append("text")
        .attr("x", PAD_SMALL)
        .attr("y", (d) => tileH(d) / 2)
        .attr("dy", "0.35em"),
      "8px",
      true
    ).text((d) => {
      const name = truncate(d.data.name, tileW(d), 8, PAD_SMALL);
      return name || `${Number(d.data.percentage).toFixed(0)}%`;
    });

    // Portrait orientation (rotated)
    const smallPortrait = small.filter((d) => tileH(d) > tileW(d));
    styleText(
      smallPortrait
        .append("text")
        .attr("text-anchor", "middle")
        .attr(
          "transform",
          (d) =>
            `translate(${tileW(d) / 2},${tileH(d) / 2}) rotate(-90)`
        ),
      "8px",
      true
    ).text((d) => {
      const name = truncate(d.data.name, tileH(d), 8, PAD_SMALL);
      return name || `${Number(d.data.percentage).toFixed(0)}%`;
    });

    // --- Tiny tiles: short % or 1-2 char abbreviation, centered ---
    const tiny = nodes.filter((d) => classify(d) === "tiny");

    styleText(
      tiny
        .append("text")
        .attr("text-anchor", "middle")
        .attr("x", (d) => tileW(d) / 2)
        .attr("y", (d) => tileH(d) / 2)
        .attr("dy", "0.35em"),
      "7px",
      true
    ).text((d) => {
      const maxChars = tileW(d) >= 18 ? 2 : 1;
      const pct = `${Number(d.data.percentage).toFixed(0)}%`;
      if (maxChars >= 2 && pct.length <= 3) return pct;
      return abbreviate(d.data.name, maxChars);
    });

    // --- Micro tiles: single centered letter, slightly transparent ---
    const micro = nodes.filter((d) => classify(d) === "micro");

    styleText(
      micro
        .append("text")
        .attr("text-anchor", "middle")
        .attr("x", (d) => tileW(d) / 2)
        .attr("y", (d) => tileH(d) / 2)
        .attr("dy", "0.35em"),
      "7px",
      true
    )
      .attr("opacity", 0.85)
      .text((d) => d.data.name[0].toUpperCase());

    // Hover interactions on the group elements
    nodes
      .on("mouseover", (_event, d) => {
        nodes
          .selectAll("rect")
          .attr("opacity", (c) =>
            c.data.name === d.data.name ? 1 : 0.3
          );
        tooltip
          .style("opacity", 1)
          .html(
            `<strong>${d.data.name}</strong><br>${d.data.formattedAmount} (${Number(d.data.percentage).toFixed(1)}%)`
          );
      })
      .on("mousemove", (event) => {
        const containerRect = this.element.getBoundingClientRect();
        const tipNode = tooltip.node();
        const tipW = tipNode.offsetWidth || 0;
        const cursorX = event.clientX - containerRect.left;
        const cursorY = event.clientY - containerRect.top;
        const fitsRight = cursorX + 12 + tipW < containerRect.width;
        tooltip
          .style("left", fitsRight ? `${cursorX + 12}px` : `${cursorX - tipW - 8}px`)
          .style("top", `${cursorY - 10}px`);
      })
      .on("mouseout", () => {
        nodes.selectAll("rect").attr("opacity", 0.9);
        tooltip.style("opacity", 0);
      });
  }
}
