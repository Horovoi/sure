class TagsController < ApplicationController
  include UniqueNameSaving

  before_action :set_tag, only: %i[edit update destroy]

  def index
    @tags = Current.family.tags.alphabetically

    render layout: "settings"
  end

  def new
    @tag = Current.family.tags.new color: Tag::COLORS.sample
  end

  def create
    @tag = Current.family.tags.new(tag_params)

    if save_unique_name(@tag)
      respond_to do |format|
        format.html { redirect_to tags_path, notice: t(".created") }
        # The tag picker's inline create: the new option comes back to insert and select.
        format.json { render json: tag_json(@tag), status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_to tags_path, alert: t(".error", error: @tag.errors.full_messages.to_sentence) }
        format.json do
          # The picker's inline create of a name that exists already picks that tag
          existing = Current.family.tags.find_by(name: @tag.name) if @tag.errors.of_kind?(:name, :taken)
          if existing
            render json: tag_json(existing), status: :ok
          else
            render json: { errors: @tag.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end
  end

  def edit
  end

  def update
    @tag.assign_attributes(tag_params)

    if save_unique_name(@tag)
      redirect_to tags_path, notice: t(".updated")
    else
      redirect_to tags_path, alert: t(".error", error: @tag.errors.full_messages.to_sentence)
    end
  end

  def destroy
    @tag.destroy!
    redirect_to tags_path, notice: t(".deleted")
  end

  def destroy_all
    Current.family.tags.destroy_all
    redirect_back_or_to tags_path, notice: t(".all_deleted")
  end

  private

    def set_tag
      @tag = Current.family.tags.find(params[:id])
    end

    def tag_params
      params.expect(tag: [ :name, :color ])
    end

    def tag_json(tag)
      tag.as_json(only: %i[id name color]).merge(
        html: render_to_string(
          partial: "DS/tag_select/option",
          formats: [ :html ],
          locals: { tag: tag, selected: true, view_helpers: helpers }
        )
      )
    end
end
