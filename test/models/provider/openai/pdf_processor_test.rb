require "test_helper"

class Provider::Openai::PdfProcessorTest < ActiveSupport::TestCase
  setup do
    @pdf_content = one_page_pdf
  end

  test "a missing pdftoppm binary raises instead of looking like an unreadable PDF" do
    processor = build_processor
    # Kernel#system returns nil when the executable cannot be started
    processor.stubs(:system).returns(nil)

    error = assert_raises(Provider::Openai::Error) do
      processor.send(:convert_pdf_to_images)
    end

    assert_match(/poppler-utils/, error.message)
  end

  test "a PDF that pdftoppm rejects gives no images" do
    processor = build_processor
    # Kernel#system returns false when the command ran and exited non-zero
    processor.stubs(:system).returns(false)

    assert_equal [], processor.send(:convert_pdf_to_images)
  end

  test "a one-page PDF renders to one PNG image" do
    skip "pdftoppm (poppler-utils) is not installed" unless pdftoppm_installed?

    images = build_processor.send(:convert_pdf_to_images)

    assert_equal 1, images.size
    assert Base64.strict_decode64(images.first).start_with?("\x89PNG".b)
  end

  test "a missing pdftoppm binary fails the vision path with that reason" do
    processor = build_processor
    processor.stubs(:extract_text_from_pdf).returns(nil)
    processor.stubs(:system).returns(nil)

    error = assert_raises(Provider::Openai::Error) { processor.process }

    assert_match(/poppler-utils/, error.message)
  end

  private
    def build_processor
      Provider::Openai::PdfProcessor.new(mock("client"), model: "gpt-4.1", pdf_content: @pdf_content)
    end

    def pdftoppm_installed?
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, "pdftoppm"))
      end
    end

    # A valid one-page PDF with a correct cross-reference table, built in memory so the
    # test needs no binary fixture file.
    def one_page_pdf
      drawing = "0 0 1 rg 20 20 100 100 re f"
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << >> >>",
        "<< /Length #{drawing.bytesize} >>\nstream\n#{drawing}\nendstream"
      ]

      pdf = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map do |body, index|
        offset = pdf.bytesize
        pdf << "#{index + 1} 0 obj\n#{body}\nendobj\n"
        offset
      end

      xref_offset = pdf.bytesize
      pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
      offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
      pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n"
      pdf
    end
end
