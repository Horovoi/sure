import SortableSectionsController from "controllers/sortable_sections";

export default class extends SortableSectionsController {
  get preferencesUrl() {
    return "/reports/update_preferences";
  }

  preferencesBody(order) {
    return { reports_section_order: order };
  }
}
