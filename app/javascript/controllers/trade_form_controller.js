import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="trade-form"
//
// Shows the fields of the selected type and hides the others. Each group is a
// fieldset: a hidden one is also disabled, so its required fields do not block
// the submit and its values are not sent.
export default class extends Controller {
  static targets = ["type", "fields"];

  // The browser can restore another type than the one the server rendered
  connect() {
    this.changeType();
  }

  changeType() {
    const type = this.typeTarget.value;

    this.fieldsTargets.forEach((fieldset) => {
      const shown = fieldset.dataset.types.split(" ").includes(type);
      fieldset.hidden = !shown;
      fieldset.disabled = !shown;
    });
  }
}
