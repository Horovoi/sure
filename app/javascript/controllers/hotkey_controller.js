import { install, uninstall } from "@github/hotkey";
import { Controller } from "@hotwired/stimulus";

const ARROW_KEYS = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"];

// Controls where an arrow key already does something: it moves the caret,
// a slider, a radio choice, a list or menu selection.
const ARROW_KEY_CONTROLS = [
  "input",
  "select",
  "textarea",
  "[contenteditable]:not([contenteditable='false'])",
  "[role='slider']",
  "[role='combobox']",
  "[role='listbox']",
  "[role='menu']",
  "[role='menubar']",
  "[role='radiogroup']",
  "[role='tablist']",
  "[role='spinbutton']",
].join(", ");

// Connects to data-controller="hotkey"
export default class extends Controller {
  connect() {
    this.installed = false;
    document.addEventListener("keydown", this.syncInstall, true);
    this.syncInstall();
  }

  disconnect() {
    document.removeEventListener("keydown", this.syncInstall, true);
    if (this.installed) uninstall(this.element);
    this.installed = false;
  }

  navigateBack(event) {
    window.history.back();
  }

  // Takes this hotkey out of @github/hotkey for keys it shouldn't answer:
  // - Keys pressed in a modal dialog this hotkey isn't part of. The library
  //   would click it through the inert page, and swallow the key, so Escape
  //   couldn't close the dialog.
  // - A held key's auto-repeats, for a link. Each one would start the same
  //   Turbo visit over again.
  // - An arrow key while a control that uses arrow keys has focus. The
  //   library skips text fields, but not checkboxes, radios, ranges or ARIA
  //   widgets.
  // Added in connect(), not as a data-action, so no hotkey can miss it, and in
  // the capture phase so it runs before the library's own keydown listener.
  syncInstall = (event) => {
    const modal =
      event?.target?.closest?.("dialog:modal") ??
      document.querySelector("dialog:modal");
    const heldLink = event?.repeat && this.element.matches("a[href]");
    const arrowInControl =
      ARROW_KEYS.includes(event?.key) &&
      !!event?.target?.closest?.(ARROW_KEY_CONTROLS) &&
      !this.element.contains(event.target);
    const active =
      (!modal || modal.contains(this.element)) && !heldLink && !arrowInControl;
    if (active === this.installed) return;

    if (active) install(this.element);
    else uninstall(this.element);
    this.installed = active;
  };
}
