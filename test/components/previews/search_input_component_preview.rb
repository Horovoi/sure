class SearchInputComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  def standalone
    render DS::SearchInput.new(placeholder: "Search currencies")
  end

  # Inside a panel that draws its own focus chrome with focus-ring-within.
  # @display container_classes max-w-[400px]
  def embedded
    content_tag(:div, class: "bg-container rounded-lg border border-secondary focus-ring-within") do
      render DS::SearchInput.new(variant: :embedded, placeholder: "Search categories")
    end
  end
end
