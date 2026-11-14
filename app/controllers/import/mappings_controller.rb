class Import::MappingsController < ApplicationController
  include ImportEditable

  before_action :set_import
  before_action :ensure_import_editable

  def update
    @mapping = @import.mappings.find(params[:id])

    @mapping.update! \
      create_when_empty: create_when_empty,
      mappable: mappable,
      value: mapping_params[:value]

    redirect_back_or_to import_confirm_path(@import)
  end

  private
    def mapping_params
      params.expect(import_mapping: [ :mappable_id, :value ])
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    # The mappable class comes from the mapping itself, never from the request
    def mappable
      mappable_class = @mapping.mappable_class
      return nil unless mappable_class.present?

      @mappable ||= mappable_class.find_by(id: mapping_params[:mappable_id], family: Current.family)
    end

    def create_when_empty
      mapping_params[:mappable_id] == Import::Mapping::CREATE_NEW_KEY
    end
end
