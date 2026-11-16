module ChatsHelper
  def chat_frame
    :sidebar_chat
  end

  def chat_view_path(chat)
    return new_chat_path if params[:chat_view] == "new"
    return chats_path if chat.nil? || params[:chat_view] == "all"

    chat.persisted? ? chat_path(chat) : new_chat_path
  end

  # The AI avatar SVG inline, with its gradient and filter ids made unique to this copy. A page holds several
  # avatars (the chat sidebar, the AI box, each answer), some hidden with display: none, and a url(#id) the
  # browser resolves into a hidden copy paints nothing: the avatar turned into a flat gray square.
  def ai_avatar_svg(file, **options)
    suffix = SecureRandom.hex(4)

    inline_svg_tag(file, **options).to_str
      .gsub(/\bid="([^"]+)"/) { %(id="#{Regexp.last_match(1)}-#{suffix}") }
      .gsub(/url\(#([^)]+)\)/) { "url(##{Regexp.last_match(1)}-#{suffix})" }
      .html_safe
  end
end
