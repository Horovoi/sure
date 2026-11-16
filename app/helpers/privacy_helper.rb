# Privacy mode blurs every element with the privacy-sensitive class (see
# app/assets/tailwind/privacy-mode.css). Most amounts get the class where they
# are formatted; these helpers cover text that arrives with amounts already in
# it: prose built from a translation or written by the assistant.
module PrivacyHelper
  # A currency amount: "$1,234.56", "-$12", "₴500", "1 234,56 €", "12,50 ₴".
  # Digit groups may be split by ".", "," or the (narrow) no-break spaces some
  # locales use, one separator at a time, so "$33, 5 days" stops after "$33".
  MONEY_FRAGMENT = /
    (?:[-−+][\s  ]?)?\p{Sc}[\s  ]?[-−]?\d(?:[.,\s  ]?\d)*   # symbol first
    |
    [-−+]?\d(?:[.,\s  ]?\d)*[\s  ]?\p{Sc}                         # symbol last
  /x

  # Wraps each amount in plain text in a privacy-sensitive span, so privacy
  # mode blurs the figures and the sentence around them stays readable. The
  # text is escaped as usual; an html_safe string passes through unchanged.
  def privacy_money_text(text)
    return text if text.blank? || text.html_safe?

    safe_join(
      text.to_s.split(/(#{MONEY_FRAGMENT})/o).map.with_index do |part, index|
        index.odd? ? tag.span(part, class: "privacy-sensitive") : part
      end
    )
  end

  # The same for rendered HTML (an assistant message): wraps the amounts in its
  # text nodes, leaving its tags and code blocks alone.
  def privacy_money_html(html)
    return html if html.blank?
    # Plain text is not markup: escape it like any other text
    return privacy_money_text(html) unless html.html_safe?

    fragment = Nokogiri::HTML5.fragment(html.to_s)
    fragment.xpath(".//text()[not(ancestor::code) and not(ancestor::pre)]").each do |node|
      next unless node.text.match?(MONEY_FRAGMENT)

      node.replace(Nokogiri::HTML5.fragment(privacy_money_text(node.text).to_s))
    end
    # Safe as the input was: the same markup, re-serialised, with spans added
    fragment.to_html.html_safe
  end
end
