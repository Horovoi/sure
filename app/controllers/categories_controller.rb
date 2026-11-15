class CategoriesController < ApplicationController
  before_action :set_category, only: %i[edit update destroy]
  before_action :set_categories, only: %i[update edit]
  before_action :set_transaction, only: :create

  def index
    @categories = Current.family.categories.alphabetically

    # Which categories have transactions (decides each row's delete flow), in one query
    @used_category_ids = Transaction.where(category_id: @categories.select(:id)).distinct.pluck(:category_id).to_set

    render layout: "settings"
  end

  def new
    @category = Current.family.categories.new color: Category::COLORS.sample
    set_categories
  end

  def create
    @category = Current.family.categories.new(category_params)

    if @category.save
      if @transaction
        @transaction.update(category_id: @category.id)
        @transaction.record_category_usage!
      end

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream do
          flash[:notice] = t(".success")
          render turbo_stream: turbo_stream.action(:redirect, redirect_target_url)
        end
        # The inline create of the category pickers: the new option's markup
        # comes back so the picker can insert and select it without a reload.
        format.json { render json: category_json(@category), status: :created }
      end
    else
      respond_to do |format|
        format.html do
          set_categories
          render :new, status: :unprocessable_entity
        end
        format.turbo_stream do
          set_categories
          render :new, formats: [ :html ], status: :unprocessable_entity
        end
        format.json { render json: { errors: @category.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      flash[:notice] = t(".success")

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category.destroy

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def destroy_all
    Current.family.categories.destroy_all
    redirect_back_or_to categories_path, notice: t(".success")
  end

  def bootstrap
    Current.family.categories.bootstrap!

    redirect_back_or_to categories_path, notice: t(".success")
  end

  private
    def set_category
      @category = Current.family.categories.find(params[:id])
    end

    def set_categories
      @categories = unless @category.parent?
        Current.family.categories.alphabetically.roots.where.not(id: @category.id)
      else
        []
      end
    end

    def set_transaction
      if params[:transaction_id].present?
        @transaction = Current.family.transactions.find(params[:transaction_id])
      end
    end

    def category_params
      params.expect(category: [ :name, :color, :parent_id, :classification, :lucide_icon ])
    end

    def category_json(category)
      category.as_json(only: %i[id name color classification parent_id]).merge(
        html: render_to_string(
          partial: "DS/category_select/option",
          formats: [ :html ],
          locals: { category: category, selected: true, view_helpers: helpers }
        )
      )
    end
end
