import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  // By default, auto-submit is "opt-in" to avoid unexpected behavior. Each `auto` target
  // will trigger a form submission when the configured event is triggered.
  static targets = ["auto"];
  static values = {
    triggerEvent: { type: String, default: "input" },
  };

  connect() {
    // Track the last value and timeouts per element to compute context-aware debouncing
    this._lastValues = new WeakMap();
    this._lastSubmitted = new WeakMap();
    this._timeouts = new WeakMap();

    this.autoTargets.forEach((element) => {
      const event = this.#getTriggerEvent(element);
      this._lastValues.set(element, this.#currentValue(element));
      element.addEventListener(event, this.handleInput);
    });
  }

  disconnect() {
    this.autoTargets.forEach((element) => {
      const event = this.#getTriggerEvent(element);
      element.removeEventListener(event, this.handleInput);
      const t = this._timeouts.get(element);
      if (t) clearTimeout(t);
    });
  }

  handleInput = (event) => {
    const el = event.target;
    const current = this.#currentValue(el);
    const previous = this._lastValues.get(el) ?? "";

    // Minimum length logic (default 0, can be customized per element)
    const minLen = this.#minLength(el);

    // If length is 0 (cleared), always submit to reset filters quickly
    if (current.length === 0) {
      this.#scheduleSubmit(el, this.#clearDebounce(el));
      this._lastValues.set(el, current);
      return;
    }

    // If below minimum, do not submit (prevents 1-char queries)
    if (current.length < minLen) {
      this._lastValues.set(el, current);
      const t = this._timeouts.get(el);
      if (t) clearTimeout(t);
      return;
    }

    // Determine if user is adding or clearing characters
    const isAdding = current.length > previous.length;
    const delay = isAdding ? this.#addDebounce(el) : this.#clearDebounce(el);

    this.#scheduleSubmit(el, delay);
    this._lastValues.set(el, current);
  };

  #scheduleSubmit(el, delay) {
    const existing = this._timeouts.get(el);
    if (existing) clearTimeout(existing);

    const snapshot = this.#currentValue(el);
    const timeout = setTimeout(() => {
      // Avoid duplicate submits for the same value
      if (this._lastSubmitted.get(el) === snapshot) return;
      this._lastSubmitted.set(el, snapshot);
      this.element.requestSubmit();
    }, delay);

    this._timeouts.set(el, timeout);
  }

  #currentValue(element) {
    // Support inputs and textareas; fall back to value/textContent
    if ("value" in element) return element.value || "";
    return (element.textContent || "").trim();
  }

  #getTriggerEvent(element) {
    // Element-level override
    if (element.dataset.autosubmitTriggerEvent) {
      return element.dataset.autosubmitTriggerEvent;
    }

    // Form-level override
    if (this.triggerEventValue !== "input") {
      return this.triggerEventValue;
    }

    // Otherwise, choose trigger event based on element type
    const type = element.type || element.tagName;

    switch (type.toLowerCase()) {
      case "text":
      case "email":
      case "password":
      case "search":
      case "tel":
      case "url":
      case "textarea":
        return "blur";
      case "number":
      case "date":
      case "datetime-local":
      case "month":
      case "time":
      case "week":
      case "color":
        return "change";
      case "checkbox":
      case "radio":
      case "select":
      case "select-one":
      case "select-multiple":
        return "change";
      case "range":
        return "input";
      default:
        return "blur";
    }
  }

  #minLength(element) {
    if (element.dataset.autosubmitMinLength) {
      const n = Number.parseInt(element.dataset.autosubmitMinLength);
      return Number.isNaN(n) ? 0 : n;
    }
    return 0;
  }

  #addDebounce(element) {
    if (element.dataset.autosubmitDebounceAddTimeout) {
      const n = Number.parseInt(element.dataset.autosubmitDebounceAddTimeout);
      if (!Number.isNaN(n)) return n;
    }
    // Fallback to shared timeout or default
    return this.#fallbackDebounce(element);
  }

  #clearDebounce(element) {
    if (element.dataset.autosubmitDebounceClearTimeout) {
      const n = Number.parseInt(element.dataset.autosubmitDebounceClearTimeout);
      if (!Number.isNaN(n)) return n;
    }
    // Clearing should generally be fast
    return 0;
  }

  #fallbackDebounce(element) {
    if (element.dataset.autosubmitDebounceTimeout) {
      const n = Number.parseInt(element.dataset.autosubmitDebounceTimeout);
      if (!Number.isNaN(n)) return n;
    }

    const type = element.type || element.tagName;

    switch (type.toLowerCase()) {
      case "input":
      case "textarea":
        return 500;
      case "select-one":
      case "select-multiple":
        return 0;
      default:
        return 500;
    }
  }
}
