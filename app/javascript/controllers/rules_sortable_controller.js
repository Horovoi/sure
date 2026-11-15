import SortableSectionsController from "controllers/sortable_sections";

// The rules list in run order. Each rule is a section whose key is the rule id;
// a drop saves the whole order (RulesController#reorder). A save the server
// refuses (the list changed in another tab) puts the last saved order back.
export default class extends SortableSectionsController {
  // Stimulus merges this with the base class values (holdDelay)
  static values = { url: String };

  get preferencesUrl() {
    return this.urlValue;
  }

  requestBody(order) {
    return { rule_ids: order };
  }
}
