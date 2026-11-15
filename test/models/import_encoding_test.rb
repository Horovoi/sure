require "test_helper"

class ImportEncodingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "successfully imports Windows-1250 encoded CSV" do
    # Test that Windows-1250 encoded files are properly converted to UTF-8
    file_path = Rails.root.join("test/fixtures/files/imports/windows1250.csv")
    csv_content = File.binread(file_path)

    # Verify the file is not UTF-8
    assert_equal Encoding::ASCII_8BIT, csv_content.encoding
    refute csv_content.force_encoding("UTF-8").valid_encoding?, "Test file should not be valid UTF-8"

    import = @family.imports.create!(
      type: "TransactionImport",
      account: @account,
      date_format: "%Y-%m-%d",
      date_col_label: "Date",
      amount_col_label: "Amount",
      name_col_label: "Name",
      category_col_label: "Category",
      tags_col_label: "Tags",
      account_col_label: "Account",
      notes_col_label: "Notes",
      signage_convention: "inflows_negative",
      amount_type_strategy: "signed_amount"
    )

    # With encoding detection, the import should succeed
    assert_nothing_raised do
      import.update!(raw_file_str: csv_content)
    end

    # Verify the raw_file_str was converted to UTF-8
    assert_equal Encoding::UTF_8, import.raw_file_str.encoding
    assert import.raw_file_str.valid_encoding?, "Converted string should be valid UTF-8"

    # Verify we can generate rows from the CSV
    assert_nothing_raised do
      import.generate_rows_from_csv
    end

    # Verify that rows were created
    import.reload
    assert import.rows_count > 0, "Expected rows to be created from Windows-1250 CSV"
    assert_equal 3, import.rows_count, "Expected 3 data rows"

    # Verify Polish characters were preserved correctly
    # Check that any row contains the Polish characters (test is about encoding, not ordering)
    assert import.rows.any? { |row| row.name&.include?("spożywczy") }, "Polish characters should be preserved"
    # Also verify other Polish characters from different rows
    assert import.rows.any? { |row| row.name&.include?("Café") }, "Extended Latin characters should be preserved"
  end

  test "handles UTF-8 files without modification" do
    # Test that valid UTF-8 files are not modified
    file_path = Rails.root.join("test/fixtures/files/imports/transactions.csv")
    csv_content = File.read(file_path, encoding: "UTF-8")

    import = @family.imports.create!(
      type: "TransactionImport",
      account: @account,
      date_format: "%Y-%m-%d",
      raw_file_str: csv_content
    )

    # UTF-8 content should remain unchanged
    assert_equal Encoding::UTF_8, import.raw_file_str.encoding
    assert import.raw_file_str.valid_encoding?
  end

  test "converts a Windows-1251 Ukrainian CSV through update!" do
    import = build_ukrainian_import
    csv_content = File.binread(file_fixture("imports/windows1251.csv"))
    refute csv_content.dup.force_encoding("UTF-8").valid_encoding?, "Test file should not be valid UTF-8"

    import.update!(raw_file_str: csv_content)

    assert_ukrainian_rows(import)
  end

  test "converts a Windows-1251 Ukrainian CSV when validations are skipped" do
    import = build_ukrainian_import
    import.assign_attributes(raw_file_str: File.binread(file_fixture("imports/windows1251.csv")))

    # Import::UploadsController#update saves this way
    assert_nothing_raised { import.save!(validate: false) }

    assert_ukrainian_rows(import)
  end

  test "a short Windows-1251 file is not mistaken for a Latin encoding" do
    import = build_ukrainian_import
    # rchardet reports ISO-8859-2 with high confidence for this one
    import.update!(raw_file_str: "Дата;Опис;Сума\n01.11.2026;Їжа;-12\n".encode("Windows-1251").b)

    assert_includes import.reload.raw_file_str, "Їжа"
  end

  test "a Cyrillic guess from the detector is read as Windows-1251" do
    import = build_ukrainian_import
    CharDet.stubs(:detect).returns({ "encoding" => "KOI8-R", "confidence" => 0.99 })

    import.update!(raw_file_str: File.binread(file_fixture("imports/windows1251.csv")))

    assert_includes import.reload.raw_file_str, "Ґудзик і нитки"
  end

  test "UTF-8 bytes read as binary stay UTF-8" do
    import = build_ukrainian_import
    import.update!(raw_file_str: "Дата;Опис;Сума\n01.11.2026;Кава;-12\n".b)

    assert_equal Encoding::UTF_8, import.raw_file_str.encoding
    assert_includes import.reload.raw_file_str, "Кава"
  end

  private
    def build_ukrainian_import
      @family.imports.create!(
        type: "TransactionImport",
        account: @account,
        col_sep: ";",
        number_format: "1 234,56",
        date_format: "%d.%m.%Y",
        date_col_label: "Дата",
        amount_col_label: "Сума",
        name_col_label: "Опис",
        category_col_label: "Категорія",
        signage_convention: "inflows_positive",
        amount_type_strategy: "signed_amount"
      )
    end

    def assert_ukrainian_rows(import)
      import.reload
      assert_equal Encoding::UTF_8, import.raw_file_str.encoding
      assert import.raw_file_str.valid_encoding?
      assert_equal %w[Дата Опис Сума Категорія], import.csv_headers

      import.generate_rows_from_csv
      rows = import.reload.rows.ordered

      assert_equal [ "Сільпо, їжа на тиждень", "Ґудзик і нитки", "Зарплата за жовтень є" ], rows.map(&:name)
      assert_equal [ "-1234.56", "-89.00", "45000.00" ], rows.map(&:amount)
      assert_equal [ "Продукти", "Побут", "Дохід" ], rows.map(&:category)
      assert rows.all?(&:valid?), rows.flat_map { |row| row.errors.full_messages }.to_sentence
    end
end
