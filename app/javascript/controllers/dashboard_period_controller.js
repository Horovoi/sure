import { Controller } from "@hotwired/stimulus";

// One period for the dashboard's period widgets (cash flow, outflows, investments and
// net worth), as upstream has it. A change in any widget's period form, or a range
// dragged on the net worth chart, goes into the page URL (period, start_date, end_date)
// and reloads each of those widgets' frames with it; the server builds only the widget a
// frame asks for. Frames, not the page, so the scroll position and an open fullscreen
// dialog stay. The Spending widget keeps its own budget month.
//
// keep targets are controls that change their widget without a request (the cash flow
// subcategory toggle): their state goes into the URL too, so the reload keeps it.
export default class extends Controller {
  static targets = ["keep"];
  static values = { frames: Array };

  // submit of a widget's period form
  change(event) {
    event.preventDefault();
    const form = event.target;
    const names = new Set(Array.from(form.elements, (element) => element.name).filter(Boolean));
    const data = new FormData(form);

    this.#apply((params) => {
      names.forEach((name) => params.delete(name));
      for (const [name, value] of data) params.append(name, value);
    });
  }

  // time-series-chart:select-range from the net worth chart
  selectRange(event) {
    event.preventDefault();
    const { startDate, endDate } = event.detail;

    this.#apply((params) => {
      params.set("period", "custom");
      params.set("start_date", startDate);
      params.set("end_date", endDate);
    });
  }

  #apply(update) {
    const url = new URL(window.location.href);
    update(url.searchParams);

    if (url.searchParams.get("period") !== "custom") {
      url.searchParams.delete("start_date");
      url.searchParams.delete("end_date");
    }
    // Off is each toggle's default, so only an on toggle goes into the URL
    for (const control of this.keepTargets) {
      if (control.checked) url.searchParams.set(control.name, control.value);
      else url.searchParams.delete(control.name);
    }
    // Customize mode's one-off focus params belong to the visit that set them
    url.searchParams.delete("hidden_section");
    url.searchParams.delete("shown_section");

    const frames = this.framesValue.map((id) => document.getElementById(id)).filter(Boolean);
    this.#keepFocus(frames);

    // The first frame's visit also replaces the page URL, through Turbo's history, so a
    // reload or a later page refresh shows the same period
    frames.forEach((frame, index) => {
      Turbo.visit(url.toString(), { frame: frame.id, action: index === 0 ? "replace" : null });
    });
  }

  // The reload replaces the control that was changed: focus its new copy, so a keyboard
  // user stays where they were
  #keepFocus(frames) {
    const focused = document.activeElement;
    const frame = frames.find((candidate) => candidate.contains(focused));
    if (!frame || !focused.id) return;

    frame.addEventListener(
      "turbo:frame-load",
      () => document.getElementById(focused.id)?.focus({ preventScroll: true }),
      { once: true },
    );
  }
}
