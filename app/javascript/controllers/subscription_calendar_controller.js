import { Controller } from "@hotwired/stimulus"
import { computePosition, offset, flip, shift, autoUpdate } from "@floating-ui/dom"

export default class extends Controller {
  static targets = ["drawer", "drawerTitle", "drawerContent", "calendarData", "hoverCard"]

  static values = {
    hoverDelay: { type: Number, default: 200 },
    longPressDelay: { type: Number, default: 400 }
  }

  connect() {
    this.calendarData = {}
    if (this.hasCalendarDataTarget) {
      try {
        this.calendarData = JSON.parse(this.calendarDataTarget.textContent)
      } catch (e) {
        console.error("Failed to parse calendar data:", e)
      }
    }

    this.hoverTimeout = null
    this.longPressTimeout = null
    this.touchStartTime = null
    this.cleanup = null
  }

  showDayDetails(event) {
    const date = event.currentTarget.dataset.date
    const subscriptions = this.calendarData[date] || []

    if (subscriptions.length === 0) {
      return
    }

    // Format the date for display
    const dateObj = new Date(date)
    const formattedDate = dateObj.toLocaleDateString('en-US', {
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    })

    this.drawerTitleTarget.textContent = formattedDate
    this.drawerContentTarget.innerHTML = this.buildSubscriptionsList(subscriptions)
    this.drawerTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  closeDayDetails() {
    this.drawerTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  buildSubscriptionsList(subscriptions) {
    if (subscriptions.length === 0) {
      return '<p class="text-secondary text-sm">No subscriptions on this day</p>'
    }

    return subscriptions.map(sub => `
      <a href="${sub.edit_url}" class="block p-3 rounded-lg hover:bg-surface-inset transition-colors mb-2 border border-secondary">
        <div class="flex items-center gap-3">
          ${sub.logo_url
            ? `<img src="${sub.logo_url}" class="w-10 h-10 rounded-full object-cover" loading="lazy" />`
            : `<div class="w-10 h-10 rounded-full flex items-center justify-center text-sm font-bold text-white ${sub.billing_cycle === 'monthly' ? 'bg-violet-500' : 'bg-yellow-500'}">${sub.name[0].toUpperCase()}</div>`
          }
          <div class="flex-1">
            <div class="font-medium text-primary">${sub.name}</div>
            <div class="text-sm text-secondary">${sub.amount}</div>
          </div>
          <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${sub.billing_cycle === 'monthly' ? 'bg-violet-100 text-violet-700' : 'bg-yellow-100 text-yellow-700'}">
            ${sub.billing_cycle === 'monthly' ? 'Monthly' : 'Yearly'}
          </span>
        </div>
      </a>
    `).join('')
  }

  // Hover card - desktop mouse events
  handleCellMouseEnter(event) {
    const cell = event.currentTarget
    const date = cell.dataset.date
    const subscriptions = this.calendarData[date] || []

    if (subscriptions.length === 0) return

    clearTimeout(this.hoverTimeout)
    this.hoverTimeout = setTimeout(() => {
      this.showHoverCard(cell, subscriptions, date)
    }, this.hoverDelayValue)
  }

  handleCellMouseLeave(event) {
    clearTimeout(this.hoverTimeout)
    this.hideHoverCard()
  }

  // Hover card - mobile touch events
  handleCellTouchStart(event) {
    const cell = event.currentTarget
    const date = cell.dataset.date
    const subscriptions = this.calendarData[date] || []

    if (subscriptions.length === 0) return

    this.touchStartTime = Date.now()
    this.longPressTimeout = setTimeout(() => {
      this.showHoverCard(cell, subscriptions, date)
    }, this.longPressDelayValue)
  }

  handleCellTouchEnd(event) {
    const elapsed = Date.now() - this.touchStartTime
    clearTimeout(this.longPressTimeout)

    if (elapsed >= this.longPressDelayValue) {
      event.preventDefault()
      setTimeout(() => this.hideHoverCard(), 2000)
    }
  }

  handleCellTouchMove(event) {
    clearTimeout(this.longPressTimeout)
  }

  showHoverCard(cell, subscriptions, date) {
    if (!this.hasHoverCardTarget) return

    this.hoverCardTarget.innerHTML = this.buildHoverCardContent(subscriptions, date)
    this.hoverCardTarget.classList.remove("hidden")
    this.positionHoverCard(cell)
  }

  hideHoverCard() {
    if (!this.hasHoverCardTarget) return

    this.hoverCardTarget.classList.add("hidden")
    if (this.cleanup) {
      this.cleanup()
      this.cleanup = null
    }
  }

  positionHoverCard(cell) {
    if (this.cleanup) this.cleanup()

    this.cleanup = autoUpdate(cell, this.hoverCardTarget, () => {
      computePosition(cell, this.hoverCardTarget, {
        placement: "right-start",
        middleware: [
          offset(8),
          flip({ fallbackPlacements: ["left-start", "bottom", "top"] }),
          shift({ padding: 8 })
        ]
      }).then(({ x, y }) => {
        Object.assign(this.hoverCardTarget.style, {
          left: `${x}px`,
          top: `${y}px`
        })
      })
    })
  }

  buildHoverCardContent(subscriptions, date) {
    const total = subscriptions.reduce((sum, sub) => {
      const amount = parseFloat(sub.amount.replace(/[^0-9.-]/g, ""))
      return sum + (isNaN(amount) ? 0 : Math.abs(amount))
    }, 0)

    const currencyMatch = subscriptions[0]?.amount?.match(/^[^0-9.-]+/)
    const currency = currencyMatch ? currencyMatch[0] : "$"
    const formattedTotal = `${currency}${total.toFixed(2)}`

    // Format date header
    const dateObj = new Date(date)
    const formattedDate = dateObj.toLocaleDateString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric'
    })

    // Service category icons
    const categoryIcons = {
      streaming: '📺',
      music: '🎵',
      software: '💻',
      gaming: '🎮',
      news: '📰',
      fitness: '💪',
      storage: '☁️',
      cloud: '☁️',
      utilities: '🔧',
      education: '📚'
    }

    const cards = subscriptions.map(sub => {
      const categoryIcon = sub.service_category ? categoryIcons[sub.service_category] || '📦' : ''
      const categoryLabel = sub.service_category ? sub.service_category.charAt(0).toUpperCase() + sub.service_category.slice(1) : ''
      const billingLabel = sub.billing_cycle === 'monthly' ? 'Mo' : 'Yr'
      const billingColor = sub.billing_cycle === 'monthly' ? 'bg-violet-100 text-violet-700' : 'bg-yellow-100 text-yellow-700'

      return `
        <div class="p-2 rounded-lg bg-surface-inset">
          <div class="flex items-center gap-2">
            ${sub.logo_url
              ? `<img src="${sub.logo_url}" class="w-6 h-6 rounded-full object-cover shrink-0" loading="lazy" />`
              : `<div class="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white shrink-0 ${sub.billing_cycle === 'monthly' ? 'bg-violet-500' : 'bg-yellow-500'}">${this.escapeHtml(sub.name[0].toUpperCase())}</div>`
            }
            <span class="text-primary text-sm font-medium truncate flex-1">${this.escapeHtml(sub.name)}</span>
            <span class="text-primary text-sm font-semibold">${sub.amount}</span>
          </div>
          <div class="flex items-center gap-2 mt-1.5 text-xs text-secondary">
            <span class="inline-flex items-center px-1.5 py-0.5 rounded ${billingColor} text-[10px] font-medium">${billingLabel}</span>
            ${categoryLabel ? `<span>${categoryIcon} ${categoryLabel}</span>` : ''}
            ${sub.account_name ? `<span class="truncate">· ${this.escapeHtml(sub.account_name)}</span>` : ''}
          </div>
        </div>
      `
    }).join('')

    return `
      <div class="space-y-2">
        <div class="text-xs font-medium text-secondary uppercase tracking-wide">${formattedDate}</div>
        ${cards}
        <div class="border-t border-secondary pt-2 flex justify-between items-center">
          <span class="text-secondary text-xs">${subscriptions.length} subscription${subscriptions.length > 1 ? 's' : ''}</span>
          <span class="text-primary text-sm font-semibold">${formattedTotal}</span>
        </div>
      </div>
    `
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  // Close on escape key
  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    clearTimeout(this.hoverTimeout)
    clearTimeout(this.longPressTimeout)
    if (this.cleanup) this.cleanup()
  }

  handleKeydown = (event) => {
    if (event.key === "Escape") {
      this.closeDayDetails()
    }
  }
}
