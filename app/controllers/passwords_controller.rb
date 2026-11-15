class PasswordsController < ApplicationController
  disallow_while_impersonating
  def edit
  end

  def update
    # has_secure_password runs without its built-in validations here, so the
    # current password must be checked explicitly.
    unless Current.user.authenticate(password_params[:password_challenge].to_s)
      Current.user.errors.add(:password_challenge, :invalid)
      render :edit, status: :unprocessable_entity
      return
    end

    if Current.user.update(password_params.except(:password_challenge))
      redirect_to root_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

    def password_params
      params.expect(user: [ :password, :password_confirmation, :password_challenge ])
    end
end
