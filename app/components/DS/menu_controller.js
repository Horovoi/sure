import {
  autoUpdate,
  computePosition,
  flip,
  offset,
  shift,
} from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";

/**
 * Strict action-list menu. Container is `role="menu"`, items are
 * `role="menuitem"`. Arrow Up/Down moves focus between items, Home/End
 * jumps to first/last, Escape closes the menu and returns focus to the
 * trigger. Use DS::Popover for mixed-content panels (forms, pickers).
 */
export default class extends Controller {
  static targets = ["button", "content"];

  static values = {
    show: Boolean,
    placement: { type: String, default: "bottom-end" },
    offset: { type: Number, default: 6 },
    mobileFullwidth: { type: Boolean, default: true },
  };

  connect() {
    this.boundUpdate = this.update.bind(this);
    this.addEventListeners();
    this.startAutoUpdate();
    // Every menu renders closed, so one that connects open is a copy Turbo
    // cached while it was open, brought back by Back.
    this.close();
  }

  // Derived from the content element's own class rather than tracked as
  // separate state. A Turbo morph (e.g. the same-page refresh after this
  // menu's own "disable account" action) re-renders the content element
  // closed without going through toggle()/close(), which would otherwise
  // leave a plain instance property out of sync with the DOM — swallowing
  // the next click because toggle() would think it still needs to close.
  get show() {
    return !this.contentTarget.classList.contains("hidden");
  }

  disconnect() {
    this.removeEventListeners();
    this.stopAutoUpdate();
    this.close();
  }

  addEventListeners() {
    this.buttonTarget.addEventListener("click", this.toggle);
    this.element.addEventListener("keydown", this.handleKeydown);
    this.contentTarget.addEventListener("click", this.handleItemClick);
    document.addEventListener("click", this.handleOutsideClick);
    document.addEventListener("turbo:load", this.handleTurboLoad);
    document.addEventListener("turbo:before-cache", this.handleBeforeCache);
    document.addEventListener("turbo:submit-end", this.handleTurboSubmitEnd);
  }

  removeEventListeners() {
    this.buttonTarget.removeEventListener("click", this.toggle);
    this.element.removeEventListener("keydown", this.handleKeydown);
    this.contentTarget.removeEventListener("click", this.handleItemClick);
    document.removeEventListener("click", this.handleOutsideClick);
    document.removeEventListener("turbo:load", this.handleTurboLoad);
    document.removeEventListener("turbo:before-cache", this.handleBeforeCache);
    document.removeEventListener("turbo:submit-end", this.handleTurboSubmitEnd);
  }

  // Never cache a page with an open menu: Back would bring it back open.
  handleBeforeCache = () => {
    this.close();
  };

  // A successful submit of a form that holds this menu closes it, so the
  // results are not left under an open panel.
  handleTurboSubmitEnd = (event) => {
    if (!this.show) return;
    if (event?.detail?.success === false) return;

    const form = event.target;
    if (form instanceof HTMLElement && form.contains(this.element)) {
      this.close();
    }
  };

  handleTurboLoad = () => {
    if (!this.show) this.close();
  };

  // A chosen link item closes the menu and hands focus back to its trigger
  // (ARIA menu pattern). Without this a link that stays on the page (one that
  // opens a modal in a Turbo frame, or a new tab) left the menu open, with
  // focus on an item that kept the page's arrow-key shortcuts away.
  handleItemClick = (event) => {
    if (!event.target.closest?.('a[role^="menuitem"]')) return;

    this.close();
    this.buttonTarget.focus({ preventScroll: true });
  };

  handleOutsideClick = (event) => {
    if (this.show && !this.element.contains(event.target)) this.close();
  };

  handleKeydown = (event) => {
    if (event.key === "Escape") {
      this.close();
      this.buttonTarget.focus();
      return;
    }
    if (!this.show) return;

    const items = this.#menuItems();
    if (items.length === 0) return;
    const currentIndex = items.indexOf(event.target);

    // Activate the focused item on Enter / Space (ARIA menu pattern).
    // Without this, link-based menuitems can't be activated by keyboard
    // once focus has moved off the native default.
    if (event.key === "Enter" || event.key === " ") {
      if (currentIndex < 0) return;
      event.preventDefault();
      items[currentIndex].click();
      return;
    }

    let nextIndex = null;
    switch (event.key) {
      case "ArrowDown":
        nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % items.length;
        break;
      case "ArrowUp":
        nextIndex = currentIndex < 0 ? items.length - 1 : (currentIndex - 1 + items.length) % items.length;
        break;
      case "Home":
        nextIndex = 0;
        break;
      case "End":
        nextIndex = items.length - 1;
        break;
      default:
        return;
    }
    event.preventDefault();
    items.forEach((item, i) => item.setAttribute("tabindex", i === nextIndex ? "0" : "-1"));
    items[nextIndex].focus();
  };

  toggle = () => {
    const nextShow = !this.show;
    this.contentTarget.classList.toggle("hidden", !nextShow);
    this.buttonTarget.setAttribute("aria-expanded", nextShow.toString());
    if (nextShow) {
      this.update();
      this.#focusFirstMenuItem();
    }
  };

  close() {
    this.contentTarget.classList.add("hidden");
    this.buttonTarget.setAttribute("aria-expanded", "false");
  }

  #menuItems() {
    // Include selectable roles (menuitemradio/menuitemcheckbox) so roving focus
    // and keyboard handling work for single/multi-select menus, not just plain
    // action items.
    return Array.from(
      this.contentTarget.querySelectorAll(
        '[role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"]',
      ),
    );
  }

  #focusFirstMenuItem() {
    const items = this.#menuItems();
    if (items.length === 0) return;
    items.forEach((item, i) => item.setAttribute("tabindex", i === 0 ? "0" : "-1"));
    items[0].focus({ preventScroll: true });
  }

  startAutoUpdate() {
    if (!this._cleanup) {
      this._cleanup = autoUpdate(
        this.buttonTarget,
        this.contentTarget,
        this.boundUpdate,
      );
    }
  }

  stopAutoUpdate() {
    if (this._cleanup) {
      this._cleanup();
      this._cleanup = null;
    }
  }

  update() {
    if (!this.buttonTarget || !this.contentTarget) return;

    const isSmallScreen = !window.matchMedia("(min-width: 768px)").matches;
    const useMobileFullwidth = isSmallScreen && this.mobileFullwidthValue;

    computePosition(this.buttonTarget, this.contentTarget, {
      placement: useMobileFullwidth ? "bottom" : this.placementValue,
      middleware: [offset(this.offsetValue), flip({ padding: 5 }), shift({ padding: 5 })],
      strategy: "fixed",
    }).then(({ x, y }) => {
      if (useMobileFullwidth) {
        Object.assign(this.contentTarget.style, {
          position: "fixed",
          left: "0px",
          width: "100vw",
          top: `${y}px`,
        });
      } else {
        Object.assign(this.contentTarget.style, {
          position: "fixed",
          left: `${x}px`,
          top: `${y}px`,
          width: "",
        });
      }
    });
  }
}
