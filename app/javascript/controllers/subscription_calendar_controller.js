import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["drawer", "drawerTitle", "drawerContent", "calendarData"]

  connect() {
    this.calendarData = {}
    if (this.hasCalendarDataTarget) {
      try {
        this.calendarData = JSON.parse(this.calendarDataTarget.textContent)
      } catch (e) {
        console.error("Failed to parse calendar data:", e)
      }
    }
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

  // Close on escape key
  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
  }

  handleKeydown = (event) => {
    if (event.key === "Escape") {
      this.closeDayDetails()
    }
  }
}
