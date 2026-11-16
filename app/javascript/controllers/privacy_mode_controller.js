import { Controller } from "@hotwired/stimulus";

const STORAGE_KEY = "privacyMode";
const CLASS_NAME = "privacy-mode";

// Privacy mode blurs every .privacy-sensitive element (see privacy-mode.css)
// while <html> has the privacy-mode class.
//
// The controller sits on <html>, so it spans every page, and Turbo visits,
// morphs and stream updates never replace it: the class stays put and new
// content is blurred as it arrives. The inline script in
// layouts/_privacy_mode_check sets the class before first paint; this
// controller owns it after that.
//
// The state is per browser (localStorage), like the theme preview: it is about
// who can see this screen, not a setting of the account. Another open tab
// follows a change through the storage event.
export default class extends Controller {
  static targets = ["toggle"];

  connect() {
    this.apply(this.storedState());
    window.addEventListener("storage", this.handleStorage);
  }

  disconnect() {
    window.removeEventListener("storage", this.handleStorage);
  }

  toggle() {
    const active = !this.active;
    try {
      localStorage.setItem(STORAGE_KEY, active.toString());
    } catch (e) {
      // No storage (private window, blocked site data): the mode still
      // applies to this page, it just isn't remembered.
    }
    this.apply(active);
  }

  // A toggle that arrives with a Turbo visit gets the current state.
  toggleTargetConnected(element) {
    element.setAttribute("aria-pressed", String(this.active));
  }

  handleStorage = (event) => {
    if (event.key === STORAGE_KEY) this.apply(event.newValue === "true");
  };

  storedState() {
    try {
      return localStorage.getItem(STORAGE_KEY) === "true";
    } catch (e) {
      return this.element.classList.contains(CLASS_NAME);
    }
  }

  apply(active) {
    this.active = active;
    this.element.classList.toggle(CLASS_NAME, active);
    for (const toggle of this.toggleTargets) {
      toggle.setAttribute("aria-pressed", String(active));
    }
  }
}
