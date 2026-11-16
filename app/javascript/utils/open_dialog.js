// Opens a <dialog> as a modal the way DS::Dialog opens itself: through its
// DS--dialog controller's open() when it has one, else showModal() and then
// focus on the dialog itself.
//
// A bare showModal() focuses the first control inside, usually the close
// button, and Safari counts that as keyboard focus and rings it as soon as the
// dialog opens. Focus on the dialog element instead: screen readers announce it
// by its label and the first Tab reaches its first control. A dialog that
// declares a starting control (autofocus, as the confirm dialog's Cancel)
// keeps it.
export default function openDialog(dialog, application) {
  if (!dialog || dialog.open || typeof dialog.showModal !== "function") return;

  const controller = application?.getControllerForElementAndIdentifier(dialog, "DS--dialog");
  if (typeof controller?.open === "function") {
    controller.open();
    return;
  }

  dialog.showModal();

  const ownAutofocus = Array.from(dialog.querySelectorAll("[autofocus]")).some(
    (el) => el.closest("dialog") === dialog,
  );
  if (ownAutofocus) return;

  if (!dialog.hasAttribute("tabindex")) dialog.setAttribute("tabindex", "-1");
  dialog.focus({ preventScroll: true });
}
