# Active Storage serves any blob to whoever holds its signed URL, and those URLs
# do not expire for redirect routes. This adds the app's login to every blob,
# representation and disk route, and checks the owning record for the record
# types below, so a leaked or guessed link to a family export, an import file,
# a family document or a transaction's receipt is a 404 for anyone outside that
# family.
#
# Account logos and avatars are not sensitive: any signed-in user may load them.
# An uploaded merchant logo is served to the merchant's family only. A blob with
# no attachment at all, or one whose record is gone, fails closed.
#
# The module is defined once, outside to_prepare, so a code reload in
# development does not redefine its constants. Only the includes run on every
# reload, because the Active Storage controllers and Authentication reload.
module ActiveStorageAttachmentAuthorization
  extend ActiveSupport::Concern

  # STI subclasses (PdfImport, FamilyMerchant, ...) are stored under their base class
  # ("Import", "Merchant").
  PROTECTED_RECORD_TYPES = %w[FamilyExport Import FamilyDocument Merchant Transaction].freeze

  # Tracked variants and previews are blobs of their own, attached to an
  # ActiveStorage::VariantRecord or to their source blob. They are authorized
  # through the attachments of the blob they were made from; a variant of a
  # preview is two steps away from its source.
  MAX_DERIVED_BLOB_DEPTH = 2

  included do
    include Authentication
    before_action :authorize_protected_attachment
  end

  private
    def authorize_protected_attachment
      # Direct uploads create unattached blobs; the code that attaches them authorizes that step.
      return if is_a?(ActiveStorage::DirectUploadsController)
      return unless authorized_blob

      attachments = authorized_attachments
      raise ActiveRecord::RecordNotFound if attachments.empty?

      protected_attachments = attachments.select { |attachment| attachment.record_type.in?(PROTECTED_RECORD_TYPES) }
      return if protected_attachments.all? { |attachment| protected_attachment_authorized?(attachment) }

      raise ActiveRecord::RecordNotFound
    end

    def protected_attachment_authorized?(attachment)
      case attachment.record_type
      when "FamilyExport"
        family_export_attachment_authorized?(attachment)
      when "Import", "FamilyDocument"
        family_record_attachment_authorized?(attachment)
      when "Merchant"
        merchant_attachment_authorized?(attachment)
      when "Transaction"
        transaction_attachment_authorized?(attachment)
      else
        false
      end
    end

    # Mirrors FamilyExportsController, which limits exports to family admins.
    def family_export_attachment_authorized?(attachment)
      family_record_attachment_authorized?(attachment) && Current.user.admin?
    end

    # Only a family merchant takes an upload. A provider merchant is shared by families,
    # so a file attached to one has no single owner and is refused.
    def merchant_attachment_authorized?(attachment)
      attachment.record.is_a?(FamilyMerchant) && family_record_attachment_authorized?(attachment)
    rescue ActiveRecord::RecordNotFound
      false
    end

    # A transaction has no family_id of its own; it belongs to its entry's account's family
    # (w3-toolstrx transaction-attachments).
    def transaction_attachment_authorized?(attachment)
      family_id = Account.joins(:entries)
        .where(entries: { entryable_type: "Transaction", entryable_id: attachment.record_id })
        .pick(:family_id)

      family_id.present? && Current.family.present? && family_id == Current.family.id
    end

    def family_record_attachment_authorized?(attachment)
      record = attachment.record
      return false if record.nil? || Current.family.nil?

      record.family_id == Current.family.id
    rescue ActiveRecord::RecordNotFound, NoMethodError
      false
    end

    def authorized_attachments
      @authorized_attachments ||= attachments_with_sources(authorized_blob)
    end

    def authorized_blob
      @blob || @representation&.blob || disk_service_blob
    end

    def disk_service_blob
      return nil unless is_a?(ActiveStorage::DiskController) && action_name == "show"

      key = decode_verified_key&.fetch(:key, nil)
      return nil if key.blank?

      # Untracked variants live under variants/<source blob key>/...
      blob_key = key.to_s[%r{\Avariants/([^/]+)/}, 1] || key
      # A signed key whose blob row is gone (purged, file not yet deleted) must not bypass the checks.
      ActiveStorage::Blob.find_by!(key: blob_key)
    rescue ActiveStorage::InvalidKeyError
      nil
    end

    def attachments_with_sources(blob, depth = 0)
      ActiveStorage::Attachment.where(blob: blob).to_a.flat_map do |attachment|
        next [ attachment ] unless derived_attachment?(attachment)

        source = derived_source_blob(attachment)
        raise ActiveRecord::RecordNotFound if source.nil? || depth >= MAX_DERIVED_BLOB_DEPTH

        attachments_with_sources(source, depth + 1)
      end
    end

    def derived_attachment?(attachment)
      attachment.record_type == "ActiveStorage::VariantRecord" ||
        (attachment.record_type == "ActiveStorage::Blob" && attachment.name == "preview_image")
    end

    def derived_source_blob(attachment)
      record = attachment.record
      record.is_a?(ActiveStorage::VariantRecord) ? record.blob : record
    rescue ActiveRecord::RecordNotFound
      nil
    end

    # Authentication redirects here; Active Storage controllers do not carry the app's route helpers.
    def new_session_url
      Rails.application.routes.url_helpers.new_session_url(active_storage_auth_url_options)
    end

    def new_registration_url
      Rails.application.routes.url_helpers.new_registration_url(active_storage_auth_url_options)
    end

    def active_storage_auth_url_options
      {
        protocol: request.protocol,
        host: request.host,
        port: request.optional_port
      }.compact
    end
end

Rails.application.config.to_prepare do
  [
    ActiveStorage::Blobs::RedirectController,
    ActiveStorage::Blobs::ProxyController,
    ActiveStorage::Representations::RedirectController,
    ActiveStorage::Representations::ProxyController,
    (ActiveStorage::DiskController if defined?(ActiveStorage::DiskController)),
    (ActiveStorage::DirectUploadsController if defined?(ActiveStorage::DirectUploadsController))
  ].compact.each do |controller|
    controller.include ActiveStorageAttachmentAuthorization unless controller < ActiveStorageAttachmentAuthorization
  end
end
