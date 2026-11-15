class Tag::DeletionsController < ApplicationController
  before_action :set_tag
  before_action :set_replacement_tag, only: :create

  def new
  end

  def create
    @tag.replace_and_destroy! @replacement_tag

    # Opened as a page of its own, the page to go back to is this deleted tag's form
    if request.referer.to_s.include?(new_tag_deletion_path(@tag))
      redirect_to tags_path, notice: t(".deleted")
    else
      redirect_back_or_to tags_path, notice: t(".deleted")
    end
  end

  private

    def set_tag
      @tag = Current.family.tags.find(params[:tag_id])
    end

    def set_replacement_tag
      if params[:replacement_tag_id].present?
        @replacement_tag = Current.family.tags.find(params[:replacement_tag_id])
      end
    end
end
