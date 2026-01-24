import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["nameField"]

  serviceSelected(event) {
    const { service } = event.detail

    // Auto-fill name if empty
    if (this.hasNameFieldTarget && !this.nameFieldTarget.value.trim()) {
      this.nameFieldTarget.value = service.name
    }
  }

  serviceCleared() {
    // Optionally clear the name field when service is cleared
    // For now, we'll leave it as is so users don't lose their edits
  }
}
