import { Controller } from "@hotwired/stimulus";

// Reloads the Turbo Frame it is put in from the page URL, then goes away. A job that
// cannot know what a viewer has picked (the dashboard's period, after a bank sync)
// appends it, and each browser fetches the widget with its own choices.
export default class extends Controller {
  connect() {
    const frame = this.element.closest("turbo-frame");
    this.element.remove();
    if (frame?.id) Turbo.visit(window.location.href, { frame: frame.id });
  }
}
