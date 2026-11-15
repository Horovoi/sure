import { Controller } from "@hotwired/stimulus";

// Keeps --app-height equal to the visible window height. iOS standalone
// PWAs report 100vh/100dvh taller than the area the app can draw in, which
// pushed the bottom nav under the home indicator. The <html> and <body>
// heights read this variable and fall back to 100dvh before it is set.
export default class extends Controller {
  connect() {
    this.updateViewport();

    this.boundResize = this.updateViewport.bind(this);
    window.addEventListener("resize", this.boundResize);
    window.addEventListener("orientationchange", this.boundResize);
  }

  disconnect() {
    window.removeEventListener("resize", this.boundResize);
    window.removeEventListener("orientationchange", this.boundResize);
  }

  updateViewport() {
    document.documentElement.style.setProperty(
      "--app-height",
      `${window.innerHeight}px`,
    );
  }
}
