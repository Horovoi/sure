class CardComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[480px]
  def default
    render DS::Card.new do
      safe_join([
        content_tag(:h2, "Budget", class: "text-lg font-semibold text-primary mb-1"),
        content_tag(:p, "A bordered surface panel for card-shaped content.", class: "text-sm text-secondary")
      ])
    end
  end
end
