import { Controller } from "@hotwired/stimulus";

// Turns whose page was re-fetched once after the stream subscription connected (see #refreshIfTurnMissed)
const refreshedTurns = new Set();

// How close to the bottom (px) the user must be for new content to keep the view scrolled down
const STICK_TO_BOTTOM_THRESHOLD = 80;

export default class extends Controller {
  static targets = ["messages", "form", "input", "submit", "pendingHint"];

  connect() {
    this.submitting = false;
    this.stickToBottom = true;

    this.element.addEventListener("submit", this.#handleSubmit, true);
    this.element.addEventListener("turbo:submit-end", this.#handleSubmitEnd);
    this.element.addEventListener("scroll", this.#handleScroll, true);

    this.#configureObserver();
    this.#syncComposer();
    this.#scrollToBottom();
  }

  disconnect() {
    this.element.removeEventListener("submit", this.#handleSubmit, true);
    this.element.removeEventListener("turbo:submit-end", this.#handleSubmitEnd);
    this.element.removeEventListener("scroll", this.#handleScroll, true);

    if (this.messagesObserver) {
      this.messagesObserver.disconnect();
    }

    clearTimeout(this.sampleQuestionTimer);
  }

  autoResize() {
    const input = this.inputTarget;
    const lineHeight = 20; // text-sm line-height (14px * 1.429 ≈ 20px)
    const maxLines = 3; // 3 lines = 60px total

    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, lineHeight * maxLines)}px`;
    input.style.overflowY =
      input.scrollHeight > lineHeight * maxLines ? "auto" : "hidden";
  }

  submitSampleQuestion(e) {
    // One sample question at a time: a second click while one is being sent does nothing
    if (this.sampleQuestionTimer || this.#busy()) return;

    this.inputTarget.value = e.params.question ?? e.currentTarget.dataset.chatQuestionParam;

    this.sampleQuestionTimer = setTimeout(() => {
      this.sampleQuestionTimer = null;
      this.formTarget.requestSubmit();
    }, 200);
  }

  // Newlines require shift+enter, otherwise submit the form (same functionality as ChatGPT and others)
  handleInputKeyDown(e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (!this.#busy()) this.formTarget.requestSubmit();
    }
  }

  // A reply is being generated (rendered from the stored turn status) or our own submit is still on its way
  #busy() {
    return this.submitting || this.#inFlightTurn() !== null;
  }

  #inFlightTurn() {
    if (!this.hasMessagesTarget) return null;
    return this.messagesTarget.querySelector('[data-turn-in-flight="true"]');
  }

  #handleSubmit = (e) => {
    if (!this.hasFormTarget || e.target !== this.formTarget) return;

    if (this.#busy()) {
      e.preventDefault();
      e.stopImmediatePropagation();
      return;
    }

    this.submitting = true;
    this.#syncComposer();
  };

  #handleSubmitEnd = () => {
    this.submitting = false;
    this.#syncComposer();
  };

  #syncComposer() {
    const busy = this.#busy();

    if (this.hasSubmitTarget) this.submitTarget.disabled = busy;
    if (this.hasPendingHintTarget) {
      this.pendingHintTarget.classList.toggle("hidden", !this.#inFlightTurn());
    }
  }

  #configureObserver() {
    this.messagesObserver = new MutationObserver((mutations) => {
      this.#syncComposer();
      this.#refreshIfTurnMissed(mutations);
      this.#autoScroll();
    });

    this.messagesObserver.observe(this.element, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["connected"],
    });
  }

  // The response job starts as soon as the turn is saved, before this page subscribes to the chat stream.
  // A turn that ends fast (for example, no LLM provider configured) can finish before the subscription, and
  // its broadcasts are lost. Once the subscription connects, re-fetch the chat once per turn to catch up.
  #refreshIfTurnMissed(mutations) {
    const connected = mutations.some(
      (m) =>
        m.type === "attributes" &&
        m.target.tagName === "TURBO-CABLE-STREAM-SOURCE" &&
        m.target.hasAttribute("connected"),
    );
    if (!connected) return;

    const turn = this.#inFlightTurn();
    if (!turn || refreshedTurns.has(turn.id)) return;
    refreshedTurns.add(turn.id);

    const frame = this.messagesTarget.closest("turbo-frame");
    if (!frame) return;

    if (frame.src) {
      frame.reload();
    } else {
      frame.src = window.location.href;
    }
  }

  // Follow new content only while the user is at the bottom; a new chat always starts at the bottom
  #autoScroll() {
    if (!this.hasMessagesTarget) return;

    if (this.messagesTarget !== this.currentMessagesElement) {
      this.stickToBottom = true;
    }

    if (this.stickToBottom) this.#scrollToBottom();
  }

  #handleScroll = (e) => {
    if (!this.hasMessagesTarget || e.target !== this.messagesTarget) return;

    const el = this.messagesTarget;
    this.stickToBottom =
      el.scrollHeight - el.scrollTop - el.clientHeight <=
      STICK_TO_BOTTOM_THRESHOLD;
  };

  #scrollToBottom = () => {
    if (!this.hasMessagesTarget) return;

    this.currentMessagesElement = this.messagesTarget;
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight;
  };
}
