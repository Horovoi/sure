import { Controller } from "@hotwired/stimulus"

// A frame's fetch that the page cut off is not an error: a lazy frame still
// loading when the user moves on. Turbo logs the failed fetch and rethrows it
// from the frame's load, which no code awaits, so the browser also reports an
// unhandled rejection (WebKit's "TypeError: Load failed", Chrome's "Failed to
// fetch"). One listener for every frame, here because this module always loads:
// a fetch failure while the page is being left, or for a frame no longer on the
// page, is dropped silently. A frame that fails on a live page still reports it.
const cancelledFrameFetchErrors = new WeakSet()
let leavingPage = false

function isCutOff(error, frame) {
  if (error?.name === "AbortError") return true

  return error instanceof TypeError && (leavingPage || !frame.isConnected)
}

// pagehide, not beforeunload: a beforeunload listener keeps the page out of the back-forward cache
window.addEventListener("pagehide", () => { leavingPage = true })
window.addEventListener("pageshow", () => { leavingPage = false })
// A Turbo visit replaces the page: frames of the old one are cut off with it
document.addEventListener("turbo:visit", () => { leavingPage = true })
document.addEventListener("turbo:load", () => { leavingPage = false })

document.addEventListener("turbo:fetch-request-error", (event) => {
  const frame = event.target
  const { error } = event.detail ?? {}
  if (!(frame instanceof HTMLElement) || frame.localName !== "turbo-frame") return
  if (!isCutOff(error, frame)) return

  event.preventDefault()
  if (error && typeof error === "object") cancelledFrameFetchErrors.add(error)
})

window.addEventListener("unhandledrejection", (event) => {
  const reason = event.reason
  if (reason && typeof reason === "object" && cancelledFrameFetchErrors.has(reason)) {
    event.preventDefault()
  }
})

// Connects to data-controller="turbo-frame-timeout"
// Shows "Timeout" when a frame's request takes too long. The timer starts when
// the frame actually sends its request, so lazy frames below the fold do not
// time out before they were ever fetched.
export default class extends Controller {
  static values = { timeout: { type: Number, default: 10000 } }

  connect() {
    this.startTimeout = this.startTimeout.bind(this)
    this.clearTimeout = this.clearTimeout.bind(this)

    this.element.addEventListener("turbo:before-fetch-request", this.startTimeout)
    // Clear on success and on failure: a failed fetch renders its own content
    this.element.addEventListener("turbo:frame-load", this.clearTimeout)
    this.element.addEventListener("turbo:fetch-request-error", this.clearTimeout)
    this.element.addEventListener("turbo:frame-missing", this.clearTimeout)

    // An eager frame may have started its request before this controller
    // connected
    if (this.element.hasAttribute("busy")) this.startTimeout()
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-fetch-request", this.startTimeout)
    this.element.removeEventListener("turbo:frame-load", this.clearTimeout)
    this.element.removeEventListener("turbo:fetch-request-error", this.clearTimeout)
    this.element.removeEventListener("turbo:frame-missing", this.clearTimeout)
    this.clearTimeout()
  }

  startTimeout(event) {
    // Requests of nested frames bubble up; only time this frame's own
    if (event && event.target !== this.element) return

    this.clearTimeout()
    this.timeoutId = setTimeout(() => {
      this.timeoutId = null
      this.handleTimeout()
    }, this.timeoutValue)
  }

  clearTimeout(event) {
    if (event && event.target !== this.element) return

    if (this.timeoutId) {
      clearTimeout(this.timeoutId)
      this.timeoutId = null
    }
  }

  handleTimeout() {
    // Replace loading content with error state
    this.element.innerHTML = `
      <div class="flex items-center justify-end gap-1">
        <div class="w-8 h-4 flex items-center justify-center">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-warning">
            <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/>
            <path d="M12 9v4"/>
            <path d="m12 17 .01 0"/>
          </svg>
        </div>
        <p class="font-mono text-right text-xs text-warning">Timeout</p>
      </div>
    `
  }
}
