import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

const WORD_SEPARATORS = /[\s&,/]+/;

// Category names are user-named; escape anything put into .html()
const escapeHtml = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );

// Draws a treemap for category breakdown (income or expense).
// Connects to data-controller="reports-treemap".
//
// colorMode "category" fills each tile with its category colour; "normal" fills it
// with the tile's normalColor (its change against normal, in the expenses block of the
// activity breakdown). A tile with an href opens it on click or Enter. Optional
// targets: chart (where the svg goes, else the element), legend (shown in normal mode)
// and modeButton (the colour mode switch, with a mode param). With a preferenceUrl,
// a chosen mode is saved as the user's reports_expense_color_mode.
export default class extends Controller {
  static targets = ["chart", "legend", "modeButton"];

  static values = {
    categories: { type: Array, default: [] },
    type: { type: String, default: "expense" },
    colorMode: { type: String, default: "category" },
    labels: { type: Object, default: {} },
    preferenceUrl: { type: String, default: "" },
  };

  _resizeObserver = null;
  _connected = false;

  connect() {
    this._connected = true;
    this._syncModeControls();
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this._container);
  }

  setColorMode(event) {
    const mode = event.params?.mode;
    if (mode !== "normal" && mode !== "category") return;
    if (mode === this.colorModeValue) return;

    this.colorModeValue = mode;
    this._saveColorMode(mode);
  }

  // Best effort: the switch works even when saving fails
  async _saveColorMode(mode) {
    if (!this.preferenceUrlValue) return;
    const headers = { "Content-Type": "application/json" };
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken;

    try {
      // keepalive: the save still arrives when the user leaves the page right away
      const response = await fetch(this.preferenceUrlValue, {
        method: "PATCH",
        keepalive: true,
        headers,
        body: JSON.stringify({ preferences: { reports_expense_color_mode: mode } }),
      });
      if (response.ok) this.element.dataset.savedColorMode = mode;
    } catch (error) {
      console.error("[Reports treemap] Could not save the color mode:", error);
    }
  }

  colorModeValueChanged() {
    if (!this._connected) return;
    this._syncModeControls();
    this._reinstall();
  }

  get _container() {
    return this.hasChartTarget ? this.chartTarget : this.element;
  }

  _label(key, fallback) {
    return this.labelsValue?.[key] || fallback;
  }

  _syncModeControls() {
    const normal = this.colorModeValue === "normal";
    this.modeButtonTargets.forEach((button) => {
      const active = button.dataset.reportsTreemapModeParam === this.colorModeValue;
      button.classList.toggle("segmented-control__segment--active", active);
      button.setAttribute("aria-pressed", active ? "true" : "false");
    });
    if (this.hasLegendTarget) this.legendTarget.classList.toggle("hidden", !normal);
    this.element.dataset.colorMode = this.colorModeValue;
  }

  _fill(data) {
    if (this.colorModeValue === "normal") return data.normalColor || "var(--color-gray-400)";
    return data.color;
  }

  _visit(href) {
    if (!href) return;
    if (window.Turbo) {
      window.Turbo.visit(href);
    } else {
      window.location.href = href;
    }
  }

  disconnect() {
    this._connected = false;
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    d3.select(this._container).selectAll("svg, .treemap-tooltip").remove();
  }

  _install() {
    const categories = this.categoriesValue;
    if (categories.length === 0) return;

    const container = this._container;
    const containerWidth = container.clientWidth;
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
          count: c.count || 0,
          avgFormatted: c.avgFormatted,
          dailyAvgFormatted: c.dailyAvgFormatted,
          rank: c.rank,
          subcategories: c.subcategories || [],
          totalSubcategories: c.totalSubcategories || 0,
          normalColor: c.normalColor,
          normalLines: c.normalLines || [],
          href: c.href || null,
        })),
      })
      .sum((d) => d.value);

    d3.treemap()
      .tile(d3.treemapSquarify)
      .size([width, height])
      .padding(3)
      .round(true)(root);

    const svg = d3
      .select(container)
      .append("svg")
      .attr("width", width)
      .attr("height", height);

    // Tooltip
    const tooltip = d3
      .select(container)
      .append("div")
      .attr("class", "treemap-tooltip")
      .style("position", "absolute")
      .style("pointer-events", "none")
      .style("opacity", 0)
      .style("border-radius", "6px")
      .style("font-size", "12px")
      .style("background", "var(--color-tooltip-bg)")
      .style("border", "1px solid var(--color-tooltip-border)")
      .style("box-shadow", "0 2px 8px rgba(0,0,0,0.12)")
      .style("color", "var(--color-text-primary)")
      .style("z-index", "10")
      .style("min-width", "220px")
      .style("max-width", "300px")
      .style("transition", "opacity 0.15s ease");

    const leaves = root.leaves();
    const nodes = svg
      .selectAll("g")
      .data(leaves)
      .enter()
      .append("g")
      .attr("transform", (d) => `translate(${d.x0},${d.y0})`)
      .attr("data-category-name", (d) => d.data.name)
      .style("pointer-events", "all");

    // A tile with an href opens its transactions, by click or from the keyboard
    const linked = nodes.filter((d) => Boolean(d.data.href));
    linked
      .attr("tabindex", 0)
      .attr("role", "link")
      .attr("aria-label", (d) => `${d.data.name}: ${d.data.formattedAmount}. ${this._label("open", "")}`.trim())
      .style("cursor", "pointer")
      .on("click", (_event, d) => this._visit(d.data.href))
      .on("keydown", (event, d) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          this._visit(d.data.href);
        }
      });

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
      // style, not the fill attribute: the normal colours are CSS variables
      .style("fill", (d) => this._fill(d.data))
      .attr("opacity", 0.9)
      .style("cursor", (d) => (d.data.href ? "pointer" : "default"));

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
      const words = str.split(WORD_SEPARATORS).filter(Boolean);
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
      .text((d) => String(d.data.name || "?")[0].toUpperCase());

    // Tooltip HTML builder
    const buildTooltipHtml = (d) => {
      const data = d.data;
      const pct = Number(data.percentage).toFixed(1);
      const barW = Math.min(Number(data.percentage), 100);
      const swatch = escapeHtml(this._fill(data));

      // Header: color dot + name + rank
      let html = `<div style="padding:12px 14px;">`;
      html += `<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:8px;">`;
      html += `<div style="display:flex;align-items:center;gap:7px;min-width:0;">`;
      html += `<span style="width:8px;height:8px;border-radius:50%;flex-shrink:0;background:${swatch};"></span>`;
      html += `<span style="font-weight:600;font-size:13px;color:var(--color-text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(data.name)}</span>`;
      html += `</div>`;
      if (data.rank) {
        html += `<span style="font-size:10px;font-weight:500;color:var(--color-text-secondary);background:var(--color-tooltip-border);border-radius:4px;padding:1px 5px;white-space:nowrap;">#${data.rank}</span>`;
      }
      html += `</div>`;

      // Amount + percentage
      html += `<div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px;">`;
      html += `<span style="font-weight:600;font-size:15px;color:var(--color-text-primary);letter-spacing:-0.01em;">${escapeHtml(data.formattedAmount)}</span>`;
      html += `<span style="font-size:12px;font-weight:500;color:var(--color-text-secondary);">${pct}%</span>`;
      html += `</div>`;

      // Percentage bar
      html += `<div style="height:3px;border-radius:2px;background:var(--color-tooltip-border);margin-bottom:10px;">`;
      html += `<div style="height:100%;border-radius:2px;width:${barW}%;background:${swatch};opacity:0.75;"></div>`;
      html += `</div>`;

      // Stats row: count, avg, daily avg
      const stats = [];
      if (data.count) {
        const txnLabel = data.count === 1 ? this._label("txn", "txn") : this._label("txns", "txns");
        stats.push(`${data.count} ${escapeHtml(txnLabel)}`);
      }
      if (data.avgFormatted) stats.push(`${escapeHtml(data.avgFormatted)} ${escapeHtml(this._label("avg", "avg"))}`);
      if (data.dailyAvgFormatted) stats.push(`${escapeHtml(data.dailyAvgFormatted)}${escapeHtml(this._label("per_day", "/day"))}`);

      if (stats.length > 0) {
        html += `<div style="font-size:11px;color:var(--color-text-secondary);letter-spacing:0.01em;">`;
        html += stats.join(` <span style="opacity:0.4;margin:0 3px;">&middot;</span> `);
        html += `</div>`;
      }

      // Against normal (expenses with a normal to compare with)
      if (data.normalLines && data.normalLines.length > 0) {
        html += `<div style="font-size:11px;color:var(--color-text-secondary);margin-top:6px;">`;
        html += data.normalLines.map((line) => `<div>${escapeHtml(line)}</div>`).join("");
        html += `</div>`;
      }

      // Subcategories section
      if (data.subcategories && data.subcategories.length > 0) {
        html += `<div style="border-top:1px solid var(--color-tooltip-border);margin-top:10px;padding-top:10px;">`;

        data.subcategories.forEach((sub) => {
          const subBarW = Math.min(sub.percentage, 100);
          html += `<div style="display:flex;align-items:center;gap:8px;margin-bottom:5px;font-size:11px;">`;
          // Mini bar
          html += `<div style="width:48px;height:4px;border-radius:2px;background:var(--color-tooltip-border);flex-shrink:0;">`;
          html += `<div style="height:100%;border-radius:2px;width:${subBarW}%;background:${escapeHtml(sub.color)};opacity:0.8;"></div>`;
          html += `</div>`;
          // Name
          html += `<span style="color:var(--color-text-primary);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(sub.name)}</span>`;
          // Amount + percentage
          html += `<span style="color:var(--color-text-secondary);white-space:nowrap;font-variant-numeric:tabular-nums;">${escapeHtml(sub.amount)}</span>`;
          html += `</div>`;
        });

        const remaining = data.totalSubcategories - data.subcategories.length;
        if (remaining > 0) {
          html += `<div style="font-size:10px;color:var(--color-text-secondary);opacity:0.7;margin-top:2px;">+${remaining} ${escapeHtml(this._label("more", "more"))}</div>`;
        }
        html += `</div>`;
      }

      html += `</div>`;
      return html;
    };

    // Hover interactions on the group elements
    nodes
      .on("mouseover", (_event, d) => {
        nodes
          .selectAll("rect")
          .attr("opacity", (c) => (c === d ? 1 : 0.3));
        tooltip
          .style("opacity", 1)
          .html(buildTooltipHtml(d));
      })
      .on("mousemove", (event) => {
        const containerRect = container.getBoundingClientRect();
        const tipNode = tooltip.node();
        const tipW = tipNode.offsetWidth || 0;
        const tipH = tipNode.offsetHeight || 0;
        const cursorX = event.clientX - containerRect.left;
        const cursorY = event.clientY - containerRect.top;
        const fitsRight = cursorX + 12 + tipW < containerRect.width;
        const maxTop = containerRect.height - tipH - 4;
        const top = Math.max(4, Math.min(cursorY - 10, maxTop));
        tooltip
          .style("left", fitsRight ? `${cursorX + 12}px` : `${cursorX - tipW - 8}px`)
          .style("top", `${top}px`);
      })
      .on("mouseout", () => {
        nodes.selectAll("rect").attr("opacity", 0.9);
        tooltip.style("opacity", 0);
      });
  }
}
