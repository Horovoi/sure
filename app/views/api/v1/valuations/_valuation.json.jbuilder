# frozen_string_literal: true

json.id valuation.entry.id
json.date valuation.entry.date
json.amount valuation.entry.amount_money.format
json.currency valuation.entry.currency
json.notes valuation.entry.notes
json.kind valuation.kind

json.account do
  json.id valuation.entry.account.id
  json.name valuation.entry.account.name
  json.account_type valuation.entry.account.accountable_type.underscore
end

json.created_at valuation.created_at.iso8601
json.updated_at valuation.updated_at.iso8601
