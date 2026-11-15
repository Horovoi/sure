import SortableSectionsController from "controllers/sortable_sections";

export default class extends SortableSectionsController {
  get preferencesUrl() {
    return "/reports/update_preferences";
  }

  preferencesBody(order) {
    return { reports_section_order: order };
  }

  handleKeyDown(event) {
    // While a section is picked up for reordering, Left and Right Arrow stay
    // with it. Otherwise the period hotkeys would leave the page before the
    // new order is saved, which only happens on release.
    if (
      (event.key === "ArrowLeft" || event.key === "ArrowRight") &&
      this.mode === "keyboard"
    ) {
      event.preventDefault();
    }

    super.handleKeyDown(event);
  }
}
