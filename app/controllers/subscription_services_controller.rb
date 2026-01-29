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

  def uncached
    icons_dir = Rails.root.join("public", "icons")
    services = SubscriptionService.all.reject { |s| File.exist?(icons_dir.join("#{s.slug}.png")) }

    render json: services.map { |s| { id: s.id, domain: s.domain, slug: s.slug } }
  end

  def cache_icon
    service = SubscriptionService.find(params[:id])
    icons_dir = Rails.root.join("public", "icons")
    FileUtils.mkdir_p(icons_dir)

    if params[:icon].present?
      File.binwrite(icons_dir.join("#{service.slug}.png"), params[:icon].read)
      head :ok
    else
      head :unprocessable_entity
    end
  end
end
