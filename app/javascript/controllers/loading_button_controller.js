import { Controller } from "@hotwired/stimulus"

// Shows a spinner on the submit button while the form submits. The busy state
// is undone when the submission ends (a failure leaves the user on the page)
// and before Turbo caches the page (so Back never restores a stuck button).
export default class extends Controller {
  static targets = ["button"]
  static values = { loadingText: String }

  connect() {
    this.reset = this.reset.bind(this)
    this.element.addEventListener("turbo:submit-end", this.reset)
    document.addEventListener("turbo:before-cache", this.reset)
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.reset)
    document.removeEventListener("turbo:before-cache", this.reset)
    this.reset()
  }

  showLoading() {
    // Don't prevent form submission, just show loading state
    if (!this.hasButtonTarget || this.originalHTML !== undefined) return

    this.originalHTML = this.buttonTarget.innerHTML
    this.buttonTarget.disabled = true
    this.buttonTarget.setAttribute("aria-disabled", "true")
    this.buttonTarget.setAttribute("aria-busy", "true")
    this.buttonTarget.innerHTML = `
      <span class="inline-flex items-center gap-2">
        <span class="animate-spin rounded-full h-4 w-4 border-b-2 border-current" aria-hidden="true"></span>
        <span>${this.loadingTextValue || 'Loading...'}</span>
      </span>
    `
  }

  reset() {
    if (!this.hasButtonTarget || this.originalHTML === undefined) return

    this.buttonTarget.innerHTML = this.originalHTML
    this.buttonTarget.disabled = false
    this.buttonTarget.removeAttribute("aria-disabled")
    this.buttonTarget.removeAttribute("aria-busy")
    this.originalHTML = undefined
  }
}
