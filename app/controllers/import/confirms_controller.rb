class Import::ConfirmsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    unless @import.cleaned?
      return redirect_to import_clean_path(@import), alert: "You have invalid data, please edit until all errors are resolved"
    end

    # Nothing to map: a cleaned import without mapping steps is publishable, so this cannot loop
    redirect_to import_path(@import) if @import.mapping_steps.empty?
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end
end
