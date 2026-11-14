import { Controller } from "@hotwired/stimulus"

// Each icon is independent (one download from the CDN, one upload to the app),
// so several are processed at once instead of waiting for each to finish.
const CONCURRENT_ICONS = 4

export default class extends Controller {
  static targets = ["button", "status"]

  async cache() {
    this.buttonTarget.disabled = true
    this.statusTarget.textContent = "Fetching uncached services..."
    this.statusTarget.classList.remove("hidden")

    try {
      const response = await fetch("/subscription_services/uncached")
      const services = await response.json()

      if (services.length === 0) {
        this.statusTarget.textContent = "All icons are already cached."
        this.buttonTarget.disabled = false
        return
      }

      const total = services.length
      let cached = 0
      let failed = 0
      let nextIndex = 0

      const worker = async () => {
        while (nextIndex < total) {
          const service = services[nextIndex++]
          this.statusTarget.textContent = `Caching ${cached + failed + 1}/${total} — ${service.domain}...`

          if (await this.cacheIcon(service)) {
            cached++
          } else {
            failed++
          }
        }
      }

      await Promise.all(Array.from({ length: Math.min(CONCURRENT_ICONS, total) }, worker))

      this.statusTarget.textContent = `Done! Cached: ${cached}, Failed: ${failed}, Total: ${total}`
    } catch (error) {
      this.statusTarget.textContent = `Error: ${error.message}`
    } finally {
      this.buttonTarget.disabled = false
    }
  }

  // Downloads one service's icon and stores it on the server. Returns whether it was cached.
  async cacheIcon(service) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const clientId = this.element.dataset.iconCacheClientIdValue
    const logoSize = this.element.dataset.iconCacheSizeValue || "40"

    try {
      const iconUrl = `https://cdn.brandfetch.io/${service.domain}/icon/fallback/lettermark/w/${logoSize}/h/${logoSize}?c=${clientId}`
      const iconResponse = await fetch(iconUrl)

      if (!iconResponse.ok || !iconResponse.headers.get("content-type")?.startsWith("image/")) {
        return false
      }

      const blob = await iconResponse.blob()
      const formData = new FormData()
      formData.append("icon", blob, `${service.slug}.png`)

      await fetch(`/subscription_services/${service.id}/cache_icon`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrfToken },
        body: formData
      })

      return true
    } catch {
      return false
    }
  }
}
