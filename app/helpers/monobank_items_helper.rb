module MonobankItemsHelper
  # Options for what to do with one product in the setup dialog. Values:
  # "create:<Type>:<subtype>", "link:<account id>" or "skip".
  def monobank_setup_choices(monobank_account, link_candidates)
    create = [
      [ t("monobank_items.setup_choices.create_checking"), "create:Depository:checking" ],
      [ t("monobank_items.setup_choices.create_savings"), "create:Depository:savings" ],
      [ t("monobank_items.setup_choices.create_credit_card"), "create:CreditCard:credit_card" ]
    ]
    link = link_candidates.map do |account|
      [ t("monobank_items.setup_choices.link", account: account.name), "link:#{account.id}" ]
    end

    create + link + [ [ t("monobank_items.setup_choices.skip"), "skip" ] ]
  end

  def monobank_setup_default_choice(monobank_account)
    type = monobank_account.suggested_account_type
    type ? "create:#{type}:#{monobank_account.suggested_subtype}" : "create:Depository:checking"
  end
end
