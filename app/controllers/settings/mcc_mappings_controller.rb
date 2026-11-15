# Saves the family's category for each merchant-code group (settings section
# settings/mcc_mappings/_section, shown on a bank connection's settings panel).
class Settings::MccMappingsController < ApplicationController
  include FamilyAdminRequired

  require_family_admin

  def update
    choices = mcc_mapping_params.fetch(:groups, {}).to_h
    MccCategoryMapping.apply!(family: Current.family, choices: choices)

    redirect_back_or_to settings_providers_path, notice: t("settings.mcc_mappings.update.saved")
  end

  private
    def mcc_mapping_params
      params.expect(mcc_mapping: [ groups: {} ])
    end
end
