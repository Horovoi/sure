# Blocks changes to an import once it has left the editable states (pending, failed,
# reverted), so nothing rewrites rows or mappings while a job is publishing them or
# after they were published. Expects @import to be set by an earlier before_action.
module ImportEditable
  extend ActiveSupport::Concern

  private
    def ensure_import_editable
      return if @import.editable?

      redirect_to import_path(@import), alert: t("imports.not_editable")
    end
end
