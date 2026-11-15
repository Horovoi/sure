# Drawn from config/routes.rb with draw(:mcc).
namespace :settings do
  resource :mcc_mapping, only: :update
end
