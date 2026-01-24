import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "dropdown", "list", "hidden", "preview", "clear"]
  static values = {
    services: Array,
    selected: String
  }

  connect() {
    this.isOpen = false
    this.selectedIndex = -1
    this.filteredServices = this.servicesValue

    // Close dropdown when clicking outside
    this.boundClose = this.closeOnClickOutside.bind(this)
    document.addEventListener("click", this.boundClose)

    // If there's a selected service, show it
    if (this.selectedValue) {
      const service = this.servicesValue.find(s => s.id === this.selectedValue)
      if (service) {
        this.selectService(service, false)
      }
    }
  }

  disconnect() {
    document.removeEventListener("click", this.boundClose)
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  toggle(event) {
    event.preventDefault()
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.isOpen = true
    this.dropdownTarget.classList.remove("hidden")
    this.inputTarget.focus()
    this.filter()
  }

  close() {
    this.isOpen = false
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  filter() {
    const query = this.inputTarget.value.toLowerCase().trim()

    if (query === "") {
      this.filteredServices = this.servicesValue
    } else {
      this.filteredServices = this.servicesValue.filter(service =>
        service.name.toLowerCase().includes(query) ||
        service.domain.toLowerCase().includes(query)
      )
    }

    this.render()
  }

  render() {
    if (this.filteredServices.length === 0) {
      this.listTarget.innerHTML = `
        <div class="px-3 py-6 text-center text-secondary text-sm">
          No services found
        </div>
      `
      return
    }

    // Group by category
    const grouped = {}
    this.filteredServices.forEach(service => {
      const cat = service.category || "other"
      if (!grouped[cat]) grouped[cat] = []
      grouped[cat].push(service)
    })

    let html = ""
    let index = 0

    Object.keys(grouped).sort().forEach(category => {
      html += `<div class="px-3 py-1 text-xs font-medium text-subdued uppercase tracking-wider bg-surface-inset">${category}</div>`

      grouped[category].forEach(service => {
        const isSelected = index === this.selectedIndex
        html += `
          <button type="button"
                  class="w-full flex items-center gap-3 px-3 py-2 hover:bg-surface-hover transition-colors ${isSelected ? 'bg-surface-hover' : ''}"
                  data-action="click->subscription-service-select#select"
                  data-service-id="${service.id}"
                  data-service-name="${service.name}"
                  data-service-logo="${service.logo_url || ''}"
                  data-service-color="${service.color || '#6B7280'}">
            ${this.renderServiceLogo(service)}
            <div class="flex-1 text-left">
              <span class="text-sm text-primary font-medium">${service.name}</span>
              <span class="text-xs text-subdued ml-2">${service.domain}</span>
            </div>
          </button>
        `
        index++
      })
    })

    this.listTarget.innerHTML = html
  }

  renderServiceLogo(service) {
    if (service.logo_url) {
      return `<img src="${service.logo_url}" class="w-6 h-6 rounded-full object-cover" loading="lazy" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">`
        + `<div class="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white" style="background-color: ${service.color || '#6B7280'}; display: none;">${service.name.charAt(0).toUpperCase()}</div>`
    }
    return `<div class="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white" style="background-color: ${service.color || '#6B7280'}">${service.name.charAt(0).toUpperCase()}</div>`
  }

  select(event) {
    event.preventDefault()
    const button = event.currentTarget
    const service = {
      id: button.dataset.serviceId,
      name: button.dataset.serviceName,
      logo_url: button.dataset.serviceLogo,
      color: button.dataset.serviceColor
    }
    this.selectService(service, true)
  }

  selectService(service, shouldFillName = true) {
    // Update hidden field
    this.hiddenTarget.value = service.id

    // Update preview
    this.previewTarget.innerHTML = `
      <div class="flex items-center gap-2">
        ${service.logo_url
          ? `<img src="${service.logo_url}" class="w-6 h-6 rounded-full object-cover" loading="lazy">`
          : `<div class="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white" style="background-color: ${service.color || '#6B7280'}">${service.name.charAt(0).toUpperCase()}</div>`
        }
        <span class="text-sm text-primary font-medium">${service.name}</span>
      </div>
    `
    this.previewTarget.classList.remove("hidden")
    this.clearTarget.classList.remove("hidden")

    // Dispatch event for auto-filling name
    if (shouldFillName) {
      this.dispatch("selected", { detail: { service } })
    }

    this.close()
    this.inputTarget.value = ""
  }

  clear(event) {
    event.preventDefault()
    this.hiddenTarget.value = ""
    this.previewTarget.innerHTML = ""
    this.previewTarget.classList.add("hidden")
    this.clearTarget.classList.add("hidden")
    this.inputTarget.value = ""
    this.dispatch("cleared")
  }

  handleKeydown(event) {
    if (!this.isOpen) {
      if (event.key === "ArrowDown" || event.key === "Enter") {
        event.preventDefault()
        this.open()
      }
      return
    }

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.selectedIndex = Math.min(this.selectedIndex + 1, this.filteredServices.length - 1)
        this.render()
        break
      case "ArrowUp":
        event.preventDefault()
        this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
        this.render()
        break
      case "Enter":
        event.preventDefault()
        if (this.selectedIndex >= 0 && this.filteredServices[this.selectedIndex]) {
          const service = this.filteredServices[this.selectedIndex]
          this.selectService(service, true)
        }
        break
      case "Escape":
        event.preventDefault()
        this.close()
        break
    }
  }
}
