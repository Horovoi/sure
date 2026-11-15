module Sure
  class << self
    # The full commit SHA this app was built from: the image build arg in
    # production, the checkout's HEAD elsewhere. nil when neither is known.
    # Memoized, so development does not shell out to git on every render.
    def commit_sha
      return @commit_sha if defined?(@commit_sha)

      @commit_sha = Rails.env.production? ? ENV["BUILD_COMMIT_SHA"].presence : git_head_sha
    end

    # The build shown in the user menu. In production it is the sure:<tag>
    # image tag that bin/deploy builds (git rev-parse --short=12), cut from
    # the full SHA the image carries. A staging "-wip" image carries the HEAD
    # SHA, so it shows HEAD without the suffix.
    def build_tag
      sha = commit_sha

      if Rails.env.production?
        sha&.first(12)
      else
        sha.present? ? "dev-#{sha.first(12)}" : "dev"
      end
    end

    private
      def git_head_sha
        sha = IO.popen(%w[git rev-parse HEAD], err: File::NULL, &:read).to_s.chomp
        sha.presence if $?&.success?
      rescue Errno::ENOENT
        # git is not installed (e.g. inside the Docker image)
        nil
      end
  end
end
