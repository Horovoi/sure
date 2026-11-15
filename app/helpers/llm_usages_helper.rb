module LlmUsagesHelper
  # A USD estimate, or "N/A" when the model has no pricing (custom or self-hosted models)
  def format_llm_cost(cost, precision:)
    return t("settings.llm_usages.show.not_available") if cost.nil?

    number_to_currency(cost, unit: "$", precision: precision)
  end
end
