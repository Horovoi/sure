import HwComboboxController from "hotwire_combobox";

// Replaces the gem's "hw-combobox" controller (same identifier) with two fixes.
export default class extends HwComboboxController {
  // The gem opens its list only on the keydown of a Latin letter, a digit or
  // ArrowDown. A Cyrillic letter, an input method, a paste or an autofill fires
  // input alone, so the list stayed closed while the async options loaded behind it.
  filterAndSelect(event) {
    if (this._isClosed && this._actingCombobox.value) {
      this.open();
      this._expand();
    }

    super.filterAndSelect(event);
  }

  // In a free-text combobox the typed text is the value, but async options take
  // it only when they arrive. Leaving the field before that cleared what was typed.
  _clearInvalidQuery() {
    if (this._isNewOptionWithPotentialMatches && this._hasEmptyFieldValue) this._selectNew();

    super._clearInvalidQuery();
  }
}
