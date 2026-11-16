import { Turbo } from "@hotwired/turbo-rails";

// Turbo 8.0.23 keeps focus across a stream render by focusing again, one
// animation frame after the stream arrives, the element (by id) that had focus
// when it arrived, if focus is then on any other element. That is for an
// element the stream replaced: it lost focus to <body>. But a click or Tab in
// that frame moves focus too, and Turbo took it back. A person who typed a
// transaction's description and clicked the amount as the description's
// suggestions arrived was put back in the description.
//
// Turbo fixed it upstream (hotwired/turbo 0c2bcb85cc, "Fix stream focus
// preservation overriding a newly focused input"): focus goes back only when it
// fell to <body> or to nothing. This applies the same rule until a release has
// it. Delete this file, and its import in application.js, when the Turbo that
// turbo-rails bundles is newer than 8.0.23 and contains that commit.
//
// How: for the one animation frame in which Turbo restores focus, the element
// that had focus ignores focus() calls while another element has focus. The
// guard is set by a frame callback queued before Turbo's and removed by one
// queued after them, so a click, a key press or a later frame never meets it.

const guards = new WeakMap();

function guard(element) {
  const existing = guards.get(element);
  if (existing) {
    existing.count += 1;
    return;
  }

  const nativeFocus = element.focus;
  guards.set(element, { count: 1 });
  element.focus = function (options) {
    const active = document.activeElement;
    if (active && active !== document.body && active !== this) return;

    nativeFocus.call(this, options);
  };
}

function unguard(element) {
  const existing = guards.get(element);
  if (!existing) return;

  existing.count -= 1;
  if (existing.count > 0) return;

  guards.delete(element);
  delete element.focus;
}

function preserveMovedFocusOnStreamRender(renderer) {
  const render = renderer.render.bind(renderer);

  renderer.render = (message) => {
    const focused = document.activeElement;
    // Turbo restores focus by id only.
    if (!focused || focused === document.body || !focused.id) return render(message);

    requestAnimationFrame(() => guard(focused));
    try {
      return render(message);
    } finally {
      requestAnimationFrame(() => unguard(focused));
    }
  };
}

preserveMovedFocusOnStreamRender(Turbo.session.streamMessageRenderer);
