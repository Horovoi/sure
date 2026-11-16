import { Controller } from "@hotwired/stimulus";

// Expand all / collapse all for a set of <details> (account groups in the
// sidebar and on the dashboard balance sheet), and which groups are open
// remembered per browser, so they stay as left across pages and reloads.
//
// Each <details> carries data-disclosure-group-key (the account group key, e.g.
// "depository"); the open keys are stored under storageKeyValue. Several
// controllers can share one storage key (the sidebar's All/Assets/Debts tabs
// show the same groups): each one only writes the keys it shows. A group the
// server opened (it holds the account on screen) stays open.
//
// The toggle target is a button: aria-expanded says whether every group is
// open, its label and icon say what a click does.
export default class extends Controller {
  static targets = ["toggle", "expandIcon", "collapseIcon"];
  static values = {
    storageKey: String,
    expandLabel: String,
    collapseLabel: String,
  };

  connect() {
    this.onToggle = (event) => {
      if (event.target.matches?.("details[data-disclosure-group-key]")) {
        this.#persist();
        this.#render();
      }
    };
    // `toggle` does not bubble: listen in the capture phase
    this.element.addEventListener("toggle", this.onToggle, true);
    this.#restore();
    this.#render();
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.onToggle, true);
  }

  toggleAll() {
    const open = !this.#allOpen();
    for (const details of this.#items()) details.open = open;
    this.#persist();
    this.#render();
  }

  #items() {
    return Array.from(
      this.element.querySelectorAll("details[data-disclosure-group-key]"),
    );
  }

  #allOpen() {
    const items = this.#items();
    return items.length > 0 && items.every((details) => details.open);
  }

  #restore() {
    const stored = this.#read();
    if (!stored) return;
    for (const details of this.#items()) {
      if (stored.has(details.dataset.disclosureGroupKey)) details.open = true;
    }
  }

  #persist() {
    const stored = this.#read() || new Set();
    for (const details of this.#items()) {
      const key = details.dataset.disclosureGroupKey;
      if (details.open) stored.add(key);
      else stored.delete(key);
    }
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify([...stored]));
    } catch (_e) {
      // Storage blocked: the state lasts for this page only
    }
  }

  #read() {
    try {
      const raw = localStorage.getItem(this.storageKeyValue);
      return raw ? new Set(JSON.parse(raw)) : null;
    } catch (_e) {
      return null;
    }
  }

  #render() {
    if (!this.hasToggleTarget) return;
    const allOpen = this.#allOpen();
    const label = allOpen ? this.collapseLabelValue : this.expandLabelValue;
    for (const toggle of this.toggleTargets) {
      toggle.setAttribute("aria-expanded", String(allOpen));
      toggle.setAttribute("aria-label", label);
      toggle.title = label;
      toggle.hidden = this.#items().length === 0;
    }
    for (const icon of this.expandIconTargets) icon.hidden = allOpen;
    for (const icon of this.collapseIconTargets) icon.hidden = !allOpen;
  }
}
