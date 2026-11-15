require "test_helper"

class ActiveStorageAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin) # dylan_family
    @member = users(:family_member) # dylan_family, role member
    @outsider = users(:empty) # another family

    @import = @admin.family.imports.create!(type: "PdfImport", date_format: "%m/%d/%Y")
    @import.pdf_file.attach(io: StringIO.new("%PDF-1.4 Family A Import"), filename: "import.pdf", content_type: "application/pdf")
  end

  test "signed out, an import blob redirects to sign in" do
    get rails_blob_path(@import.pdf_file)

    assert_redirected_to new_session_url
  end

  test "signed out, a disk service url redirects to sign in" do
    sign_in @admin
    disk_url = disk_url_for(rails_blob_path(@import.pdf_file))
    sign_out @admin

    get disk_url

    assert_redirected_to new_session_url
  end

  test "a user of the same family can read an import blob" do
    sign_in @member

    get rails_blob_path(@import.pdf_file)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "a user of another family gets 404 for an import blob" do
    sign_in @outsider

    get rails_blob_path(@import.pdf_file)

    assert_response :not_found
  end

  test "a user of another family gets 404 for an import disk url" do
    sign_in @admin
    disk_url = disk_url_for(rails_blob_path(@import.pdf_file))
    sign_out @admin
    sign_in @outsider

    get disk_url

    assert_response :not_found
  end

  test "a family admin can read the family export" do
    export = attach_family_export(@admin.family)
    sign_in @admin

    get rails_blob_path(export.export_file)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "a member who is not an admin gets 404 for the family export" do
    export = attach_family_export(@admin.family)
    sign_in @member

    get rails_blob_path(export.export_file)

    assert_response :not_found
  end

  test "an admin of another family gets 404 for the family export" do
    export = attach_family_export(@admin.family)
    sign_in @outsider

    get rails_blob_path(export.export_file)

    assert_response :not_found
  end

  test "family documents follow the family" do
    document = @admin.family.family_documents.create!(filename: "tax.pdf", status: "ready")
    document.file.attach(io: StringIO.new("Family A Tax Return"), filename: "tax.pdf", content_type: "application/pdf")

    sign_in @outsider
    get rails_blob_path(document.file)
    assert_response :not_found

    sign_out @outsider
    sign_in @member
    get rails_blob_path(document.file)
    assert_response :redirect
  end

  test "a blob attached to a protected record is checked even when it is also attached elsewhere" do
    document = @outsider.family.family_documents.create!(filename: "import.pdf", status: "ready")
    document.file.attach(@import.pdf_file.blob)

    sign_in @outsider
    get rails_blob_path(document.file)

    assert_response :not_found
  end

  test "variants follow the record of their source blob" do
    document = @admin.family.family_documents.create!(filename: "scan.png", status: "ready")
    document.file.attach(io: file_fixture("square-placeholder.png").open, filename: "scan.png", content_type: "image/png")
    variant = document.file.variant(resize_to_limit: [ 20, 20 ]).processed
    disk_url = disk_url_for(rails_representation_path(variant))

    sign_in @outsider
    get rails_representation_path(variant)
    assert_response :not_found
    get rails_blob_path(variant.image.blob)
    assert_response :not_found
    get disk_url
    assert_response :not_found

    sign_out @outsider
    sign_in @admin
    get disk_url
    assert_response :success
  end

  test "a profile image variant loads for a signed-in user" do
    @admin.profile_image.attach(io: file_fixture("profile_image.png").open, filename: "avatar.png", content_type: "image/png")
    variant = @admin.profile_image.variant(:small).processed

    sign_in @admin
    get rails_representation_path(variant)
    assert_response :redirect
    follow_redirect!
    assert_response :success

    get disk_url_for(rails_blob_path(variant.image.blob))
    assert_response :success
  end

  test "an account logo loads for a signed-in user" do
    account = accounts(:depository)
    account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")

    sign_in @member
    get rails_blob_path(account.logo)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "an orphaned import attachment fails closed" do
    attachment = @import.pdf_file.attachment
    attachment.update_columns(record_id: SecureRandom.uuid)

    sign_in @admin
    get rails_blob_path(attachment)

    assert_response :not_found
  end

  test "an unattached blob fails closed" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("unattached"), filename: "unattached.csv", content_type: "text/csv")

    sign_in @admin
    get rails_blob_path(blob)

    assert_response :not_found
  end

  test "direct uploads require a login" do
    post rails_direct_uploads_path, params: { blob: direct_upload_params }, as: :json

    assert_redirected_to new_session_url
  end

  test "a signed-in user can still make a direct upload" do
    sign_in @admin

    post rails_direct_uploads_path, params: { blob: direct_upload_params }, as: :json

    assert_response :success
    assert response.parsed_body["signed_id"].present?
  end

  test "every attachment is either access-checked or intentionally public" do
    # Logos and avatars are not sensitive. Bank provider items (*Item#logo) carry institution logos.
    public_attachments = %w[User#profile_image Account#logo RecurringTransaction#logo]

    Rails.application.eager_load!
    unchecked = ActiveRecord::Base.descendants.reject(&:abstract_class?).flat_map do |model|
      # Only the app's own models; framework records (Active Storage, Action Text, ...) are not served here.
      next [] unless Object.const_source_location(model.name)&.first.to_s.start_with?(Rails.root.join("app").to_s)

      model.reflect_on_all_attachments.filter_map do |reflection|
        record_type = model.base_class.name
        next if record_type.in?(ActiveStorageAttachmentAuthorization::PROTECTED_RECORD_TYPES)
        next if reflection.name == :logo && record_type.end_with?("Item")

        attachment = "#{record_type}##{reflection.name}"
        attachment unless attachment.in?(public_attachments)
      end
    end

    assert_empty unchecked.uniq, "Add new attachment owners to PROTECTED_RECORD_TYPES or mark them public here"
  end

  test "a family merchant logo loads for its family only" do
    merchant = merchants(:netflix) # dylan_family
    merchant.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")

    sign_in @member
    get rails_blob_path(merchant.logo)
    assert_response :redirect
    disk_url = response.location
    follow_redirect!
    assert_response :success

    sign_out @member
    sign_in @outsider
    get rails_blob_path(merchant.logo)
    assert_response :not_found
    get disk_url
    assert_response :not_found
  end

  test "a file attached to a provider merchant fails closed" do
    merchant = ProviderMerchant.create!(name: "Shared", source: "plaid")
    merchant.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")

    sign_in @admin
    get rails_blob_path(merchant.logo)

    assert_response :not_found
  end

  # w3-toolstrx transaction-attachments
  test "a transaction receipt loads for its family only" do
    transaction = entries(:transaction).transaction # dylan_family
    transaction.attachments.attach(io: file_fixture("receipt.pdf").open, filename: "receipt.pdf", content_type: "application/pdf")
    attachment = transaction.attachments.last

    sign_in @member
    get rails_blob_path(attachment)
    assert_response :redirect
    disk_url = response.location
    follow_redirect!
    assert_response :success

    sign_out @member
    sign_in @outsider
    get rails_blob_path(attachment)
    assert_response :not_found
    get disk_url
    assert_response :not_found
    get transaction_attachment_path(transaction, attachment)
    assert_response :not_found
  end

  test "a variant of a transaction receipt follows the transaction's family" do
    transaction = entries(:transaction).transaction
    transaction.attachments.attach(io: file_fixture("square-placeholder.png").open, filename: "photo.png", content_type: "image/png")
    variant = transaction.attachments.last.variant(resize_to_limit: [ 20, 20 ]).processed

    sign_in @outsider
    get rails_representation_path(variant)
    assert_response :not_found

    sign_out @outsider
    sign_in @admin
    get rails_representation_path(variant)
    assert_response :redirect
  end

  private
    def attach_family_export(family)
      export = family.family_exports.create!(status: :completed)
      export.export_file.attach(io: StringIO.new("zip"), filename: "export.zip", content_type: "application/zip")
      export
    end

    # Follows a blob or representation route to the disk service url it redirects to.
    def disk_url_for(path)
      signed_in = cookies[:session_token].present?
      sign_in @admin unless signed_in
      get path
      assert_response :redirect
      location = response.location
      sign_out @admin unless signed_in
      location
    end

    def sign_out(user)
      user.sessions.destroy_all
    end

    def direct_upload_params
      {
        filename: "statement.csv",
        byte_size: 1,
        checksum: Digest::MD5.base64digest("1"),
        content_type: "text/csv"
      }
    end
end
