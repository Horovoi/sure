class Settings::GuidesController < ApplicationController
  layout "settings"

  # GitHub's admonition markers ("> [!TIP]") and the DS::Alert variant each one is drawn as
  ADMONITION_VARIANTS = {
    "note" => :info,
    "tip" => :success,
    "important" => :info,
    "warning" => :warning,
    "caution" => :error
  }.freeze

  ADMONITION_CLASSES = {
    info: "bg-info/10 border-info/20",
    success: "bg-success/10 border-success/20",
    warning: "bg-warning/10 border-warning/20",
    error: "bg-destructive/10 border-destructive/20"
  }.freeze

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("settings.guides.show.title"), nil ]
    ]
    markdown = Redcarpet::Markdown.new(Redcarpet::Render::HTML,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      superscript: true
    )
    @guide_content = with_admonitions(markdown.render(File.read(Rails.root.join("docs/onboarding/guide.md"))))
  end

  private
    # Redcarpet leaves "[!IMPORTANT]" as the text of a blockquote. Each such quote becomes
    # a callout drawn as DS::Alert draws one, titled in words instead of the marker.
    def with_admonitions(html)
      fragment = Nokogiri::HTML::DocumentFragment.parse(html)

      fragment.css("blockquote").each do |quote|
        first = quote.at_css("p")
        marker = first&.inner_html&.match(/\A\s*\[!(\w+)\]\s*(?:<br\s*\/?>)?\s*/i)
        next unless marker && ADMONITION_VARIANTS.key?(marker[1].downcase)

        kind = marker[1].downcase
        first.inner_html = first.inner_html.delete_prefix(marker[0])
        first.remove if first.inner_html.strip.empty?

        callout = Nokogiri::XML::Node.new("div", fragment.document)
        callout["role"] = "note"
        callout["class"] = "not-prose my-4 p-4 rounded-lg border text-sm text-primary space-y-2 [&_ul]:list-disc [&_ul]:pl-5 [&_a]:text-link [&_a]:underline #{ADMONITION_CLASSES[ADMONITION_VARIANTS[kind]]}"

        title = Nokogiri::XML::Node.new("p", fragment.document)
        title["class"] = "font-medium"
        title.content = t("settings.guides.show.admonitions.#{kind}")
        callout.add_child(title)
        quote.children.each { |child| callout.add_child(child) }
        quote.replace(callout)
      end

      fragment.to_html
    end
end
