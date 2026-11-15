# Pagy's `pagy` method with one change: a page number past the end gives the last page
# instead of an empty one (a bookmarked page 9 after rows were deleted, or a larger
# page size chosen while on a late page).
#
# Controllers get the page number from the request. Anything else passes it, together
# with `request: { params: {} }`.
module Paginatable
  extend ActiveSupport::Concern
  include Pagy::Method

  private
    def pagy(collection, **options)
      pagy, records = super
      return [ pagy, records ] if pagy.page <= pagy.last

      super(collection, **options, page: pagy.last)
    end
end
