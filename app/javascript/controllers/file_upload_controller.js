import { Controller } from "@hotwired/stimulus"

// File picker with an "Uploading…" busy state. The busy state is undone when
// the submission ends and before Turbo caches the page, so Back or a failed
// upload never leaves the area stuck.
export default class extends Controller {
  static targets = ["input", "fileName", "uploadArea", "uploadText"]

  connect() {
    // Keep the bound handlers so disconnect removes the same functions
    this.fileSelected = this.fileSelected.bind(this)
    this.formSubmitting = this.formSubmitting.bind(this)
    this.submitEnded = this.submitEnded.bind(this)
    this.beforeCache = this.beforeCache.bind(this)

    if (this.hasInputTarget) {
      this.inputTarget.addEventListener("change", this.fileSelected)
    }

    // Find the form element
    this.form = this.element.closest("form")
    if (this.form) {
      this.form.addEventListener("turbo:submit-start", this.formSubmitting)
      this.form.addEventListener("turbo:submit-end", this.submitEnded)
    }

    document.addEventListener("turbo:before-cache", this.beforeCache)
  }

  disconnect() {
    if (this.hasInputTarget) {
      this.inputTarget.removeEventListener("change", this.fileSelected)
    }

    if (this.form) {
      this.form.removeEventListener("turbo:submit-start", this.formSubmitting)
      this.form.removeEventListener("turbo:submit-end", this.submitEnded)
    }

    document.removeEventListener("turbo:before-cache", this.beforeCache)
  }

  triggerFileInput() {
    if (this.hasInputTarget) {
      this.inputTarget.click()
    }
  }

  fileSelected() {
    if (this.hasInputTarget && this.inputTarget.files.length > 0) {
      const fileName = this.inputTarget.files[0].name

      if (this.hasFileNameTarget) {
        // Find the paragraph element inside the fileName target
        const fileNameText = this.fileNameTarget.querySelector('p')
        if (fileNameText) {
          fileNameText.textContent = fileName
        }

        this.fileNameTarget.classList.remove("hidden")
      }

      if (this.hasUploadTextTarget) {
        this.uploadTextTarget.classList.add("hidden")
      }
    }
  }

  formSubmitting() {
    if (this.hasFileNameTarget && this.hasInputTarget && this.inputTarget.files.length > 0) {
      const fileNameText = this.fileNameTarget.querySelector('p')
      if (fileNameText) {
        fileNameText.textContent = `Uploading ${this.inputTarget.files[0].name}...`
      }

      // Change the icon to a loader
      const iconContainer = this.fileNameTarget.querySelector('.lucide-file-text')
      if (iconContainer) {
        iconContainer.classList.add('animate-pulse')
      }
    }

    if (this.hasUploadAreaTarget) {
      this.uploadAreaTarget.classList.add("opacity-70")
    }
  }

  // The submission finished (or failed) and we are still on the page: show
  // the chosen file again instead of "Uploading…"
  submitEnded() {
    this.clearBusy()
    this.fileSelected()
  }

  // A cached copy loses the chosen file, so restore the empty picker
  beforeCache() {
    this.clearBusy()

    if (this.hasFileNameTarget) {
      this.fileNameTarget.classList.add("hidden")
      const fileNameText = this.fileNameTarget.querySelector('p')
      if (fileNameText) fileNameText.textContent = ""
    }

    if (this.hasUploadTextTarget) {
      this.uploadTextTarget.classList.remove("hidden")
    }
  }

  clearBusy() {
    if (this.hasFileNameTarget) {
      this.fileNameTarget.querySelector('.lucide-file-text')?.classList.remove('animate-pulse')
    }

    if (this.hasUploadAreaTarget) {
      this.uploadAreaTarget.classList.remove("opacity-70")
    }
  }
}
