class SubscriptionServicesController < ApplicationController
  def index
    services = SubscriptionService.alphabetically

    if params[:search].present?
      services = services.search(params[:search])
    end

    if params[:category].present?
      services = services.by_category(params[:category])
    end

    render json: services.limit(100).map { |s|
      {
        id: s.id,
        name: s.name,
        slug: s.slug,
        domain: s.domain,
        category: s.category,
        color: s.color,
        logo_url: s.logo_url
      }
    }
  end
end
