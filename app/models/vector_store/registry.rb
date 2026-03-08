class VectorStore::Registry
  ADAPTERS = {
    openai: "VectorStore::Openai"
  }.freeze

  class << self
    def adapter
      name = adapter_name
      return nil unless name

      build_adapter(name)
    end

    def configured?
      adapter.present?
    end

    def adapter_name
      explicit = ENV["VECTOR_STORE_PROVIDER"].presence
      return explicit.to_sym if explicit && ADAPTERS.key?(explicit.to_sym)

      :openai if openai_access_token.present?
    end

    private
      def build_adapter(name)
        klass = ADAPTERS[name]&.safe_constantize
        raise VectorStore::ConfigurationError, "Unknown vector store adapter: #{name}" unless klass

        case name
        when :openai
          build_openai
        else
          raise VectorStore::ConfigurationError, "No builder defined for adapter: #{name}"
        end
      end

      def build_openai
        token = openai_access_token
        return nil unless token.present?

        VectorStore::Openai.new(
          access_token: token,
          uri_base: ENV["OPENAI_URI_BASE"].presence || Setting.openai_uri_base
        )
      end

      def openai_access_token
        ENV["OPENAI_ACCESS_TOKEN"].presence || Setting.openai_access_token
      end
  end
end
