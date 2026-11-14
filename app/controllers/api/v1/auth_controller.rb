module Api
  module V1
    class AuthController < BaseController
      include Invitable

      skip_before_action :authenticate_request!
      skip_before_action :check_api_key_rate_limit
      skip_before_action :log_api_access

      def signup
        if signup_closed?
          render json: { error: "Signup is closed" }, status: :forbidden
          return
        end

        # Check if invite code is required
        if invite_code_required? && params[:invite_code].blank?
          render json: { error: "Invite code is required" }, status: :forbidden
          return
        end

        # Validate password
        password_errors = validate_password(user_signup_params[:password])
        if password_errors.any?
          render json: { errors: password_errors }, status: :unprocessable_entity
          return
        end

        # Validate device info
        unless valid_device_info?
          render json: { error: "Device information is required" }, status: :bad_request
          return
        end

        user = User.new(user_signup_params)

        # Create family for new user
        # First user of an instance becomes super_admin
        family = Family.new
        user.family = family
        user.role = User.role_for_new_family_creator

        # The invite code is claimed in the same transaction as the user, so
        # a failed signup keeps the code and two signups cannot share one.
        invalid_invite_code = false
        created = false
        User.transaction do
          if params[:invite_code].present? && !InviteCode.claim!(params[:invite_code])
            invalid_invite_code = true
            raise ActiveRecord::Rollback
          end

          raise ActiveRecord::Rollback unless user.save

          created = true
        end

        if invalid_invite_code
          render json: { error: "Invalid invite code" }, status: :forbidden
        elsif created
          # Create device and OAuth token
          device = create_or_update_device(user)
          token_response = create_oauth_token_for_device(user, device)

          render json: token_response.merge(
            user: {
              id: user.id,
              email: user.email,
              first_name: user.first_name,
              last_name: user.last_name
            }
          ), status: :created
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def login
        user = User.find_by(email: params[:email])

        # Same rule as the web login form: when local login is turned off,
        # only a super admin may use the emergency override.
        unless AuthConfig.local_login_allowed_for?(user)
          render json: { error: "Local login is disabled" }, status: :forbidden
          return
        end

        if user&.active? && user.authenticate(params[:password])
          # Check MFA if enabled
          if user.otp_required?
            unless params[:otp_code].present? && user.verify_otp?(params[:otp_code])
              render json: {
                error: "Two-factor authentication required",
                mfa_required: true
              }, status: :unauthorized
              return
            end
          end

          # Validate device info
          unless valid_device_info?
            render json: { error: "Device information is required" }, status: :bad_request
            return
          end

          # Create device and OAuth token
          device = create_or_update_device(user)
          token_response = create_oauth_token_for_device(user, device)

          render json: token_response.merge(
            user: {
              id: user.id,
              email: user.email,
              first_name: user.first_name,
              last_name: user.last_name
            }
          )
        else
          render json: { error: "Invalid email or password" }, status: :unauthorized
        end
      end

      def refresh
        # Find the refresh token
        refresh_token = params[:refresh_token]

        unless refresh_token.present?
          render json: { error: "Refresh token is required" }, status: :bad_request
          return
        end

        # Find the access token associated with this refresh token
        access_token = Doorkeeper::AccessToken.by_refresh_token(refresh_token)

        # Rotate under a row lock: of two concurrent refreshes with the same
        # token, only the first mints a new token; the second sees it revoked.
        new_token = access_token&.with_lock do
          user = User.find_by(id: access_token.resource_owner_id)
          next nil if access_token.revoked? || !user&.active?

          access_token.revoke
          Doorkeeper::AccessToken.create!(
            application: access_token.application,
            resource_owner_id: access_token.resource_owner_id,
            expires_in: 30.days.to_i,
            scopes: access_token.scopes,
            use_refresh_token: true
          )
        end

        unless new_token
          render json: { error: "Invalid refresh token" }, status: :unauthorized
          return
        end

        # Update device last seen (the device param is optional here)
        if (device_id = params.dig(:device, :device_id)).present?
          User.find(access_token.resource_owner_id).mobile_devices.find_by(device_id: device_id)&.update_last_seen!
        end

        render json: {
          access_token: new_token.plaintext_token,
          refresh_token: new_token.plaintext_refresh_token,
          token_type: "Bearer",
          expires_in: new_token.expires_in,
          created_at: new_token.created_at.to_i
        }
      end

      private

        def user_signup_params
          params.expect(user: [ :email, :password, :first_name, :last_name ])
        end

        def validate_password(password)
          errors = []

          if password.blank?
            errors << "Password can't be blank"
            return errors
          end

          errors << "Password must be at least 8 characters" if password.length < 8
          errors << "Password must include both uppercase and lowercase letters" unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
          errors << "Password must include at least one number" unless password.match?(/\d/)
          errors << "Password must include at least one special character" unless password.match?(/[!@#$%^&*(),.?":{}|<>]/)

          errors
        end

        def valid_device_info?
          device = params[:device]
          return false if device.nil?

          required_fields = %w[device_id device_name device_type os_version app_version]
          required_fields.all? { |field| device[field].present? }
        end

        def create_or_update_device(user)
          # Handle both string and symbol keys
          device_data = params[:device].permit(:device_id, :device_name, :device_type, :os_version, :app_version)

          device = user.mobile_devices.find_or_initialize_by(device_id: device_data[:device_id])
          device.update!(device_data.merge(last_seen_at: Time.current))
          device
        end

        def create_oauth_token_for_device(user, device)
          # Create OAuth application for this device if needed
          oauth_app = device.create_oauth_application!

          # Revoke any existing tokens for this device
          device.revoke_all_tokens!

          # Create new access token with 30-day expiration
          access_token = Doorkeeper::AccessToken.create!(
            application: oauth_app,
            resource_owner_id: user.id,
            expires_in: 30.days.to_i,
            scopes: "read_write",
            use_refresh_token: true
          )

          {
            access_token: access_token.plaintext_token,
            refresh_token: access_token.plaintext_refresh_token,
            token_type: "Bearer",
            expires_in: access_token.expires_in,
            created_at: access_token.created_at.to_i
          }
        end
    end
  end
end
