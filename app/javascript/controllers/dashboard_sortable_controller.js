import SortableSectionsController from "controllers/sortable_sections";

export default class extends SortableSectionsController {
  get preferencesUrl() {
    return "/dashboard/preferences";
  }

  preferencesBody(order) {
    return { section_order: order };
  }
}
