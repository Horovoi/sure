import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="transaction-type-tabs" (shared/_transaction_type_tabs),
// inside the new-transaction and new-transfer forms.
//
// Each tab loads its own form into the modal, so a switch used to drop what the
// user had typed. Before Turbo follows the tab's link, this copies the values
// typed so far into the link as query parameters (draft[...], plus the account),
// and the server fills the other form with them. The server builds that form,
// so the category list still follows the new tab's nature; a category is only
// carried between tabs of the same nature.
export default class extends Controller {
  carry(event) {
    const link = event.currentTarget
    const form = this.element.closest("form")
    if (!form) return

    const data = new FormData(form)
    const url = new URL(link.getAttribute("href"), window.location.origin)
    const toTransfer = link.dataset.tabKind === "transfer"

    const set = (name, value) => {
      if (value) url.searchParams.set(name, value)
    }

    const account = this.read(data, "entry[account_id]", "transfer[from_account_id]")
    if (toTransfer) {
      if (!url.searchParams.has("from_account_id")) set("from_account_id", account)
      set("to_account_id", this.read(data, "transfer[to_account_id]"))
    } else if (!url.searchParams.has("account_id")) {
      // An account the form was opened for stays fixed (account_id); one picked in
      // the form is only preselected
      set("draft[account_id]", account)
    }

    set("draft[amount]", this.read(data, "entry[amount]", "transfer[amount]"))
    set("draft[date]", this.read(data, "entry[date]", "transfer[date]"))

    if (!toTransfer) {
      set("draft[name]", this.read(data, "entry[name]"))
      set("draft[currency]", this.read(data, "entry[currency]"))
      set("draft[notes]", this.read(data, "entry[notes]"))
      set("draft[merchant_id]", this.read(data, "entry[entryable_attributes][merchant_id]"))

      const sameNature = url.searchParams.get("nature") === this.read(data, "entry[nature]")
      if (sameNature) set("draft[category_id]", this.read(data, "entry[entryable_attributes][category_id]"))
    }

    const tagIds = [ ...data.getAll("entry[entryable_attributes][tag_ids][]"), ...data.getAll("transfer[tag_ids][]") ]
      .filter((value) => typeof value === "string" && value !== "")
    for (const id of new Set(tagIds)) url.searchParams.append("draft[tag_ids][]", id)

    link.setAttribute("href", url.pathname + url.search)
  }

  // The first non-blank value among the named fields
  read(data, ...names) {
    for (const name of names) {
      const value = data.get(name)
      if (typeof value === "string" && value.trim() !== "") return value.trim()
    }
    return null
  }
}
