# Serves the web app manifest and the service worker from app/views/pwa/.
#
# Inherits from ActionController::Base, not ApplicationController: browsers
# fetch these files on every page load, signed in or not, and they need none
# of the app's session, onboarding, locale or sync before-actions.
class PwaController < ActionController::Base
  # The service worker is a GET for JavaScript, which Rails' cross-origin
  # check would reject, and neither file carries user data.
  skip_forgery_protection

  # Always JSON, whatever the Accept header: Safari asks for the manifest
  # with text/html, and format negotiation would then miss the template.
  def manifest
    render "pwa/manifest", formats: [ :json ], content_type: "application/manifest+json"
  end

  # Always JavaScript, for the same reason.
  def service_worker
    render "pwa/service-worker", formats: [ :js ], content_type: "application/javascript"
  end
end
