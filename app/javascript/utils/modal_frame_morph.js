import { Turbo } from "@hotwired/turbo-rails";

// A link inside an open modal that loads another dialog into the same modal frame
// (the Expense / Income / Transfer tabs of the new-transaction form) used to
// replace the <dialog>: the open one was removed, so its backdrop went away, and
// the new one opened a moment later, so the page behind blinked on every switch
// (in Safari a whole frame without the backdrop). Morphing the frame's children
// keeps the same <dialog> open and modal and only changes its content; the
// dialog controller already refuses to drop `open` during a morph.
document.addEventListener("turbo:before-frame-render", (event) => {
  const frame = event.target;
  if (frame.id !== "modal") return;

  const open = frame.querySelector("dialog[open]");
  const incoming = event.detail.newFrame?.querySelector("dialog");
  if (!open || !incoming) return;

  event.detail.render = (currentElement, newElement) => {
    Turbo.morphChildren(currentElement, newElement);
  };
});
