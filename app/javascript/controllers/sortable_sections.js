import { Controller } from "@hotwired/stimulus";

// Shared base for the reorderable sections on the dashboard and the reports
// page. Subclasses set `preferencesUrl` and `preferencesBody(order)`.
// When a save fails, the sections go back to the last order the server
// confirmed, so the page never shows an order that was not stored.
//
// One explicit mode says which gesture owns the sections, so the gestures can
// never overlap:
//   idle          nothing is happening
//   mouse         an HTML5 drag of a section is in progress
//   touch-pending a finger is on a drag handle, waiting for the hold delay
//   touch         the hold fired; the finger is dragging a section
//   keyboard      a section was grabbed with Enter/Space; arrows move it
const MODES = ["idle", "mouse", "touch-pending", "touch", "keyboard"];

// A finger that moves further than this before the hold fires is scrolling
const TOUCH_SLOP_PX = 10;

const DRAG_CLASSES = ["opacity-50", "scale-[1.02]"];
const GRAB_CLASSES = ["ring-2", "ring-primary", "ring-offset-2"];
const PLACEHOLDER_CLASSES = [
  "border-t-4",
  "border-b-4",
  "border-primary",
  "border-t-2",
  "border-b-2",
];

export default class SortableSectionsController extends Controller {
  static targets = ["section", "handle"];

  // Short delay to prevent accidental touches on the grip handle
  static values = {
    holdDelay: { type: Number, default: 150 },
  };

  connect() {
    this.mode = "idle";
    this.activeSection = null;
    this.holdTimer = null;
    this.touchStartY = 0;
    this.currentTouchY = 0;
    this.saveRequestId = 0;
    this.confirmedRequestId = 0;
    this.savedOrder = this.currentOrder();

    this.beforeCacheHandler = () => this.reset();
    document.addEventListener("turbo:before-cache", this.beforeCacheHandler);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.beforeCacheHandler);
    this.reset();
  }

  // ===== Mouse Drag Events =====
  dragStart(event) {
    // Drags of text or links inside a section are not section moves
    if (event.target !== event.currentTarget) return;
    if (this.mode === "keyboard") this.releaseKeyboardGrab();
    if (this.mode !== "idle") return;

    this.setMode("mouse", event.currentTarget);
    this.activeSection.classList.add("opacity-50");
    this.activeSection.setAttribute("aria-grabbed", "true");
    event.dataTransfer.effectAllowed = "move";
  }

  dragEnd() {
    if (this.mode !== "mouse") return;
    this.reset();
  }

  dragOver(event) {
    // Keep cancelling dragover so a dropped file does not navigate away
    event.preventDefault();

    if (this.mode !== "mouse") {
      event.dataTransfer.dropEffect = "none";
      return;
    }

    event.dataTransfer.dropEffect = "move";
    this.showPlaceholderAt(event.clientY);
  }

  drop(event) {
    event.preventDefault();
    event.stopPropagation();

    // Ignore drops of anything that is not one of our sections (text, files)
    if (this.mode !== "mouse") return;

    this.moveActiveSectionTo(event.clientY);
    this.reset();
    this.saveOrder();
  }

  // ===== Touch Events =====
  // Touch events are bound to the drag handle only, with a short hold delay
  // to prevent accidental touches.

  touchStart(event) {
    if (this.mode !== "idle") return;

    const section = this.sectionTargets.find((s) =>
      s.contains(event.currentTarget),
    );
    if (!section) return;

    this.setMode("touch-pending", section);
    this.touchStartY = event.touches[0].clientY;
    this.currentTouchY = this.touchStartY;

    this.holdTimer = setTimeout(() => this.activateDrag(), this.holdDelayValue);
  }

  activateDrag() {
    this.holdTimer = null;
    if (this.mode !== "touch-pending") return;

    this.setMode("touch", this.activeSection);
    this.activeSection.classList.add(...DRAG_CLASSES);
    this.activeSection.setAttribute("aria-grabbed", "true");

    // Haptic feedback if available
    if (navigator.vibrate) {
      navigator.vibrate(30);
    }
  }

  touchMove(event) {
    const y = event.touches[0].clientY;

    if (this.mode === "touch-pending") {
      // The finger moved before the hold fired, so this is a scroll
      if (Math.abs(y - this.touchStartY) > TOUCH_SLOP_PX) this.reset();
      return;
    }

    if (this.mode !== "touch") return;

    event.preventDefault();
    this.currentTouchY = y;
    this.showPlaceholderAt(y);
  }

  touchEnd() {
    if (this.mode !== "touch") {
      this.reset();
      return;
    }

    this.moveActiveSectionTo(this.currentTouchY);
    this.reset();
    this.saveOrder();
  }

  touchCancel() {
    if (this.mode === "touch" || this.mode === "touch-pending") this.reset();
  }

  // ===== Keyboard Navigation =====
  handleKeyDown(event) {
    // Keys pressed in controls inside a section (selects, buttons, links,
    // inputs) belong to those controls. Only the section itself and its drag
    // handle reorder.
    const onHandle = this.handleTargets.includes(event.target);
    if (event.target !== event.currentTarget && !onHandle) return;

    const section = event.currentTarget;
    const grabbed = this.mode === "keyboard" && this.activeSection === section;

    switch (event.key) {
      case "ArrowUp":
        if (!grabbed) return;
        event.preventDefault();
        this.moveUp(section);
        break;
      case "ArrowDown":
        if (!grabbed) return;
        event.preventDefault();
        this.moveDown(section);
        break;
      case "Enter":
      case " ":
        if (this.mode !== "idle" && this.mode !== "keyboard") return;
        event.preventDefault();
        this.toggleGrabMode(section);
        break;
      case "Escape":
        if (this.mode !== "keyboard") return;
        event.preventDefault();
        this.releaseKeyboardGrab();
        break;
    }
  }

  toggleGrabMode(section) {
    if (this.mode === "keyboard" && this.activeSection === section) {
      this.releaseKeyboardGrab();
    } else {
      this.grabWithKeyboard(section);
    }
  }

  grabWithKeyboard(section) {
    // Release any previously grabbed element
    if (this.mode === "keyboard") this.releaseKeyboardGrab();

    this.setMode("keyboard", section);
    section.setAttribute("aria-grabbed", "true");
    section.classList.add(...GRAB_CLASSES);
  }

  releaseKeyboardGrab() {
    if (this.mode !== "keyboard") return;

    this.reset();
    this.saveOrder();
  }

  moveUp(section) {
    const previousSibling = section.previousElementSibling;
    if (previousSibling?.hasAttribute("data-section-key")) {
      this.element.insertBefore(section, previousSibling);
      section.focus();
    }
  }

  moveDown(section) {
    const nextSibling = section.nextElementSibling;
    if (nextSibling?.hasAttribute("data-section-key")) {
      this.element.insertBefore(nextSibling, section);
      section.focus();
    }
  }

  // ===== State =====
  setMode(mode, section = null) {
    if (!MODES.includes(mode)) throw new Error(`Unknown sortable mode ${mode}`);

    this.mode = mode;
    this.activeSection = section;
  }

  // Back to idle from any mode: stop the hold timer and remove every
  // transient class, so nothing survives into the Turbo cache.
  reset() {
    if (this.holdTimer) {
      clearTimeout(this.holdTimer);
      this.holdTimer = null;
    }

    this.sectionTargets.forEach((section) => {
      section.classList.remove(
        ...DRAG_CLASSES,
        ...GRAB_CLASSES,
        ...PLACEHOLDER_CLASSES,
      );
      section.setAttribute("aria-grabbed", "false");
    });

    this.setMode("idle");
  }

  // ===== Placement =====
  moveActiveSectionTo(y) {
    if (!this.activeSection) return;

    const afterElement = this.getDragAfterElement(y);
    if (afterElement == null) {
      this.element.appendChild(this.activeSection);
    } else {
      this.element.insertBefore(this.activeSection, afterElement);
    }
  }

  showPlaceholderAt(y) {
    const afterElement = this.getDragAfterElement(y);
    this.clearPlaceholders();

    if (afterElement == null) {
      this.showPlaceholder(this.element.lastElementChild, "after");
    } else {
      this.showPlaceholder(afterElement, "before");
    }
  }

  getDragAfterElement(y) {
    const draggableElements = this.sectionTargets.filter(
      (section) => section !== this.activeSection,
    );

    return draggableElements.reduce(
      (closest, child) => {
        const box = child.getBoundingClientRect();
        const offset = y - box.top - box.height / 2;

        if (offset < 0 && offset > closest.offset) {
          return { offset: offset, element: child };
        }
        return closest;
      },
      { offset: Number.NEGATIVE_INFINITY },
    ).element;
  }

  showPlaceholder(element, position) {
    if (!element) return;

    if (position === "before") {
      element.classList.add("border-t-4", "border-primary");
    } else {
      element.classList.add("border-b-4", "border-primary");
    }
  }

  clearPlaceholders() {
    this.sectionTargets.forEach((section) => {
      section.classList.remove(...PLACEHOLDER_CLASSES);
    });
  }

  // ===== Persistence =====
  currentOrder() {
    return this.sectionTargets.map((section) => section.dataset.sectionKey);
  }

  // Put the sections back in the given order (used when a save fails, so the
  // page never shows an order the server does not have)
  applyOrder(order) {
    const byKey = new Map(
      this.sectionTargets.map((section) => [section.dataset.sectionKey, section]),
    );
    order.forEach((key) => {
      const section = byKey.get(key);
      if (section) this.element.appendChild(section);
    });
  }

  async saveOrder() {
    const order = this.currentOrder();
    if (order.join("\n") === this.savedOrder.join("\n")) return;

    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    const requestId = ++this.saveRequestId;
    let ok = false;

    if (csrfToken) {
      try {
        const response = await fetch(this.preferencesUrl, {
          method: "PATCH",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken.content,
          },
          body: JSON.stringify({ preferences: this.preferencesBody(order) }),
        });
        ok = response.ok;
        if (!ok) console.error("Failed to save section order:", response.status);
      } catch (error) {
        console.error("Network error saving section order:", error);
      }
    } else {
      console.error("CSRF token not found. Cannot save section order.");
    }

    if (ok) {
      // A slower, older request must not overwrite a newer confirmed order
      if (requestId > this.confirmedRequestId) {
        this.confirmedRequestId = requestId;
        this.savedOrder = order;
      }
      return;
    }

    // Only the latest attempt decides what the page shows
    if (requestId !== this.saveRequestId || !this.element.isConnected) return;

    this.reset();
    this.applyOrder(this.savedOrder);
  }
}
