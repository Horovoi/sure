import { Controller } from "@hotwired/stimulus";

// The window width below which only one side panel fits beside the main column. The
// layout CSS (max-xl:group-data-[left-panel=open]/layout:w-0) uses the same
// width to hide the assistant panel while the accounts panel is open.
const ONE_PANEL_QUERY = "(width >= 1024px) and (width < 1280px)";

// Connects to data-controller="app-layout"
export default class extends Controller {
  static targets = [
    "leftSidebar",
    "rightSidebar",
    "mobileSidebar",
    "leftToggle",
    "rightToggle",
    "mobileToggle",
  ];
  static values = { userId: String };
  static classes = [
    "expandedSidebar",
    "collapsedSidebar",
    "expandedTransition",
    "collapsedTransition",
  ];

  connect() {
    this.onePanelQuery = window.matchMedia(ONE_PANEL_QUERY);
    this.syncHandler = () => this.#sync();
    this.onePanelQuery.addEventListener("change", this.syncHandler);
    this.#sync();
  }

  disconnect() {
    this.onePanelQuery?.removeEventListener("change", this.syncHandler);
  }

  // The accounts drawer on a phone is a modal <dialog>: focus moves into it, the page
  // behind it is inert and Escape closes it (the dialog's own "close" event)
  openMobileSidebar() {
    if (!this.hasMobileSidebarTarget || this.mobileSidebarTarget.open) return;

    this.mobileSidebarTarget.showModal();
    this.#setExpanded(this.mobileToggleTargets, true);
  }

  closeMobileSidebar() {
    if (!this.hasMobileSidebarTarget || !this.mobileSidebarTarget.open) return;

    this.mobileSidebarTarget.close();
  }

  mobileSidebarClosed() {
    this.#setExpanded(this.mobileToggleTargets, false);
  }

  toggleLeftSidebar() {
    const open = !this.#leftShown();
    this.#setPanel(this.leftSidebarTarget, "show_sidebar", open);

    // No room for both: the assistant panel steps aside
    if (open && this.#onePanelOnly() && this.#hasExpandedClass(this.rightSidebarTarget)) {
      this.#setPanel(this.rightSidebarTarget, "show_ai_sidebar", false);
    }

    this.#sync();
  }

  toggleRightSidebar() {
    const open = !this.#rightShown();

    if (open && this.#onePanelOnly() && this.#leftShown()) {
      this.#setPanel(this.leftSidebarTarget, "show_sidebar", false);
    }

    // When the panel was only pushed aside by the accounts panel, its own setting is
    // already "show"
    if (open !== this.#hasExpandedClass(this.rightSidebarTarget)) {
      this.#setPanel(this.rightSidebarTarget, "show_ai_sidebar", open);
    }

    this.#sync();
  }

  // Opens the chat sidebar if it is closed ("Dig in with AI" loads a chat into it)
  openRightSidebar() {
    if (this.#rightShown()) return;

    this.toggleRightSidebar();
  }

  #onePanelOnly() {
    return this.onePanelQuery?.matches ?? false;
  }

  #leftShown() {
    return this.#hasExpandedClass(this.leftSidebarTarget);
  }

  #rightShown() {
    return this.#hasExpandedClass(this.rightSidebarTarget) && !(this.#onePanelOnly() && this.#leftShown());
  }

  #hasExpandedClass(el) {
    return this.expandedSidebarClasses.every((c) => el.classList.contains(c));
  }

  // The state the CSS and screen readers see: data-left-panel for the one-panel rule,
  // aria-expanded on the toggles, and inert on a hidden panel so Tab skips its contents
  #sync() {
    if (!this.hasLeftSidebarTarget || !this.hasRightSidebarTarget) return;

    const leftShown = this.#leftShown();
    const rightShown = this.#rightShown();

    this.element.dataset.leftPanel = leftShown ? "open" : "closed";
    this.leftSidebarTarget.inert = !leftShown;
    this.rightSidebarTarget.inert = !rightShown;
    this.#setExpanded(this.leftToggleTargets, leftShown);
    this.#setExpanded(this.rightToggleTargets, rightShown);
  }

  #setExpanded(buttons, expanded) {
    buttons.forEach((button) => button.setAttribute("aria-expanded", String(expanded)));
  }

  #setPanel(el, preference, open) {
    if (open) {
      el.classList.add(...this.expandedSidebarClasses);
      el.classList.remove(...this.collapsedSidebarClasses);
    } else {
      el.classList.remove(...this.expandedSidebarClasses);
      el.classList.add(...this.collapsedSidebarClasses);
    }

    this.#updateUserPreference(preference, open);
  }

  #updateUserPreference(field, value) {
    fetch(`/users/${this.userIdValue}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
        Accept: "application/json",
      },
      body: new URLSearchParams({
        [`user[${field}]`]: value,
      }).toString(),
    });
  }
}
