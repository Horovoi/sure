// A link inside an open modal that loads another dialog into the same modal frame
// (the Expense / Income / Transfer tabs of the new-transaction form) used to
// replace the <dialog>: the open one was removed, so its backdrop went away, and
// the new one opened a moment later, so the page behind blinked on every switch.
//
// The open <dialog> stays (open, modal, its backdrop untouched) and only its
// content is swapped, in one step. The content is not morphed: a morph reuses the
// old form's fields for the new form's, and their style transitions then animate
// every changed size and position, so the form slid about for a moment.
document.addEventListener("turbo:before-frame-render", (event) => {
  const frame = event.target;
  if (frame.id !== "modal") return;

  const open = frame.querySelector("dialog[open]");
  const incoming = event.detail.newFrame?.querySelector("dialog");
  if (!open || !incoming) return;

  event.detail.render = () => {
    syncAttributes(open, incoming);
    open.replaceChildren(...incoming.childNodes);
    focusContent(open);
  };
});

// The incoming dialog's attributes (classes, values for the dialog controller),
// keeping what belongs to the open one: `open`, and the tabindex its controller set
function syncAttributes(current, next) {
  const keep = new Set([ "open", "tabindex" ]);
  for (const { name } of [ ...current.attributes ]) {
    if (!keep.has(name) && !next.hasAttribute(name)) current.removeAttribute(name);
  }
  for (const { name, value } of [ ...next.attributes ]) {
    if (keep.has(name)) continue;
    if (current.getAttribute(name) !== value) current.setAttribute(name, value);
  }
}

// The tab that was clicked left with the old content. Focus moves as on open: to a
// field the form asks for (autofocus), else to the dialog itself, so it is not
// lost to <body> and Tab goes on inside the dialog.
function focusContent(dialog) {
  const autofocus = [ ...dialog.querySelectorAll("[autofocus]") ].find((el) => el.closest("dialog") === dialog);
  if (autofocus) {
    autofocus.focus();
    return;
  }
  if (!dialog.hasAttribute("tabindex")) dialog.setAttribute("tabindex", "-1");
  dialog.focus({ preventScroll: true });
}
