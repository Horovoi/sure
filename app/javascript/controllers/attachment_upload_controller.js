import { Controller } from "@hotwired/stimulus";

// Upload form of a transaction's Attachments section. Shows the picked file names and
// blocks a pick the server would refuse (too many or too large files). The server
// checks again; this only saves a round trip. Labels come from the locale files.
export default class extends Controller {
  static targets = ["fileInput", "submitButton", "fileName", "fileNameText", "uploadText"];
  static values = {
    maxFiles: Number,
    maxSize: Number,
    uploadLabel: String,
    uploadOneLabel: String,
    uploadManyLabel: String,
    tooManyLabel: String,
    tooLargeLabel: String,
  };

  connect() {
    this.updateSubmitButton();
  }

  triggerFileInput() {
    this.fileInputTarget.click();
  }

  updateSubmitButton() {
    const files = Array.from(this.fileInputTarget.files || []);
    const hasFiles = files.length > 0;

    this.#toggle(this.uploadTextTarget, !hasFiles);
    if (this.hasFileNameTarget) this.#toggle(this.fileNameTarget, hasFiles);
    if (this.hasFileNameTextTarget) {
      this.fileNameTextTarget.textContent = files.map((file) => file.name).join(", ");
    }

    let error = null;
    if (files.length > this.maxFilesValue) {
      error = this.tooManyLabelValue;
    } else if (files.some((file) => file.size > this.maxSizeValue)) {
      error = this.tooLargeLabelValue;
    }

    this.submitButtonTarget.disabled = !hasFiles || error !== null;
    this.submitButtonTarget.textContent = this.#label(files.length, error);
  }

  #label(count, error) {
    if (error) return error;
    if (count === 0) return this.uploadLabelValue;
    if (count === 1) return this.uploadOneLabelValue;

    return this.uploadManyLabelValue.replace("{count}", count);
  }

  #toggle(element, visible) {
    element.classList.toggle("hidden", !visible);
    element.classList.toggle("flex", visible);
  }
}
