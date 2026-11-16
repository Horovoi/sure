import {
  autoUpdate,
  computePosition,
  flip,
  offset,
  shift,
} from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";
import { FULL_WIDTH_QUERY, overlayMiddlewareOptions } from "utils/overlay_boundary";

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
    this.contentTarget.addEventListener("pointermove", this.handlePointerMove);
    document.addEventListener("click", this.handleOutsideClick);
    document.addEventListener("turbo:load", this.handleTurboLoad);
    document.addEventListener("turbo:before-cache", this.handleBeforeCache);
    document.addEventListener("turbo:submit-end", this.handleTurboSubmitEnd);
  }

  removeEventListeners() {
    this.buttonTarget.removeEventListener("click", this.toggle);
    this.element.removeEventListener("keydown", this.handleKeydown);
    this.contentTarget.removeEventListener("click", this.handleItemClick);
    this.contentTarget.removeEventListener("pointermove", this.handlePointerMove);
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

  // Any chosen item closes the menu and hands focus back to its trigger
  // (ARIA menu pattern): links, button_to buttons and items with a
  // turbo-confirm. This click handler runs before the form submits and before
  // Turbo's document-level link handler, so the menu is closed before a
  // confirm dialog opens over it, and the dialog returns focus to the trigger.
  // Without this a link that stays on the page (one that opens a modal in a
  // Turbo frame, or a new tab) left the menu open, with focus on an item that
  // kept the page's arrow-key shortcuts away.
  handleItemClick = (event) => {
    const item = event.target.closest?.('[role^="menuitem"]');
    if (!item || !this.contentTarget.contains(item)) return;
    if (item.matches(":disabled, [aria-disabled='true']")) return;

    this.close();
    this.buttonTarget.focus({ preventScroll: true });
  };

  // The pointer takes over from the arrow keys: its hover fill shows again.
  // A zero-distance move is a browser refreshing hover after a scroll.
  handlePointerMove = (event) => {
    if (event.movementX === 0 && event.movementY === 0) return;
    delete this.contentTarget.dataset.menuRoving;
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
    // While the arrow keys rove, the item under a resting pointer drops its
    // hover fill, so the focused item is the only one highlighted
    this.contentTarget.dataset.menuRoving = "";
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
    delete this.contentTarget.dataset.menuRoving;
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

    // Below lg the panel spans the window, like its px-2 lg:px-0 gutter
    const isSmallScreen = window.matchMedia(FULL_WIDTH_QUERY).matches;
    const bounds = overlayMiddlewareOptions(this.buttonTarget);
    const useMobileFullwidth = isSmallScreen && this.mobileFullwidthValue;

    computePosition(this.buttonTarget, this.contentTarget, {
      placement: useMobileFullwidth ? "bottom" : this.placementValue,
      // Below the trigger and aligned to its edge, flipped above or shifted
      // when that leaves the window or the content column
      middleware: [offset(this.offsetValue), flip(bounds.flip), shift(bounds.shift)],
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
