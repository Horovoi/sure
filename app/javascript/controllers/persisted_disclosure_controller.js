import { Controller } from "@hotwired/stimulus";

// Remembers whether a <details> section is open, per device, so a panel the
// user has collapsed stays collapsed instead of reappearing on every render.
// Same storage approach as privacy mode and the sidebar width.
//
// The element keeps its server-rendered `open` state until connect() runs, so
// a collapsed section flashes open for a frame on a cold load. Reading storage
// in connect() rather than waiting for a turbo event keeps that to one frame.
//
// Storage can be unavailable (blocked site data, some private windows); the
// section then just keeps its server-rendered state.
export default class extends Controller {
  static values = { key: String };

  connect() {
    const stored = this.read();
    if (stored !== null) this.element.open = stored === "true";

    this.toggleHandler = () => {
      this.write(String(this.element.open));
    };
    this.element.addEventListener("toggle", this.toggleHandler);
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.toggleHandler);
  }

  read() {
    try {
      return localStorage.getItem(this.storageKey);
    } catch {
      return null;
    }
  }

  write(value) {
    try {
      localStorage.setItem(this.storageKey, value);
    } catch {
      // Not remembered on this device; nothing else to do.
    }
  }

  get storageKey() {
    return `disclosure:${this.keyValue}`;
  }
}
