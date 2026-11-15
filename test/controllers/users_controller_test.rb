require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "can supply custom redirect after update" do
    patch user_url(@user), params: { user: { redirect_to: "home" } }
    assert_redirected_to root_url
  end

  test "client cannot set or clear onboarding timestamps directly" do
    onboarded_at = @user.onboarded_at
    assert_not_nil onboarded_at

    patch user_url(@user), params: { user: { onboarded_at: "", set_onboarding_goals_at: "", set_onboarding_preferences_at: 1.year.ago } }

    @user.reload
    assert_equal onboarded_at.to_i, @user.onboarded_at.to_i
  end

  test "server stamps the onboarding step the user finished" do
    @user.update!(onboarded_at: nil, set_onboarding_preferences_at: nil, set_onboarding_goals_at: nil)

    patch user_url(@user), params: { user: { onboarding_step: "preferences", redirect_to: "goals" } }
    assert_redirected_to goals_onboarding_url
    assert_not_nil @user.reload.set_onboarding_preferences_at
    assert_nil @user.onboarded_at

    patch user_url(@user), params: { user: { onboarding_step: "goals", redirect_to: "home" } }
    assert_redirected_to root_url
    @user.reload
    assert_not_nil @user.set_onboarding_goals_at
    assert_not_nil @user.onboarded_at
  end

  test "goals step finishes onboarding in managed mode without a missing trial route" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    @user.update!(onboarded_at: nil)

    get goals_onboarding_url
    assert_response :success
    assert_select "input[name='user[redirect_to]'][value='home']"
  end

  test "can update user profile" do
    patch user_url(@user), params: {
      user: {
        first_name: "John",
        last_name: "Doe",
        onboarded_at: Time.current,
        profile_image: file_fixture_upload("profile_image.png", "image/png", :binary),
        family_attributes: {
          name: "New Family Name",
          country: "US",
          date_format: "%m/%d/%Y",
          currency: "USD",
          locale: "en"
        }
      }
    }

    assert_redirected_to settings_profile_url
    assert_equal "Your profile has been updated.", flash[:notice]
  end

  test "admin can reset family data" do
    account = accounts(:investment)
    category = categories(:income)
    tag = tags(:one)
    merchant = merchants(:netflix)
    import = imports(:transaction)
    budget = budgets(:one)
    plaid_item = plaid_items(:one)

    provider = mock
    provider.expects(:remove_item).with(plaid_item.access_token).once
    PlaidItem.any_instance.stubs(:plaid_provider).returns(provider)

    perform_enqueued_jobs(only: FamilyResetJob) do
      delete reset_user_url(@user)
    end

    assert_redirected_to settings_profile_url
    assert_equal I18n.t("users.reset.success"), flash[:notice]

    assert_not Account.exists?(account.id)
    assert_not Category.exists?(category.id)
    assert_not Tag.exists?(tag.id)
    assert_not Merchant.exists?(merchant.id)
    assert_not Import.exists?(import.id)
    assert_not Budget.exists?(budget.id)
    assert_not PlaidItem.exists?(plaid_item.id)
  end

  test "admin can reset family data and load sample data" do
    account = accounts(:investment)
    category = categories(:income)
    tag = tags(:one)
    merchant = merchants(:netflix)
    import = imports(:transaction)
    budget = budgets(:one)
    plaid_item = plaid_items(:one)

    provider = mock
    provider.expects(:remove_item).with(plaid_item.access_token).once
    PlaidItem.any_instance.stubs(:plaid_provider).returns(provider)
    Demo::Generator.any_instance.expects(:generate_new_user_data_for!).with(@user.family, email: @user.email)

    perform_enqueued_jobs(only: FamilyResetJob) do
      delete reset_with_sample_data_user_url(@user)
    end

    assert_redirected_to settings_profile_url
    assert_equal I18n.t("users.reset_with_sample_data.success"), flash[:notice]

    assert_not Account.exists?(account.id)
    assert_not Category.exists?(category.id)
    assert_not Tag.exists?(tag.id)
    assert_not Merchant.exists?(merchant.id)
    assert_not Import.exists?(import.id)
    assert_not Budget.exists?(budget.id)
    assert_not PlaidItem.exists?(plaid_item.id)
  end

  test "non-admin cannot reset family data" do
    sign_in @member = users(:family_member)

    delete reset_user_url(@member)

    assert_redirected_to settings_profile_url
    assert_equal I18n.t("users.reset.unauthorized"), flash[:alert]
    assert_no_enqueued_jobs only: FamilyResetJob
  end

  test "non-admin cannot reset family data with sample data" do
    sign_in @member = users(:family_member)

    delete reset_with_sample_data_user_url(@member)

    assert_redirected_to settings_profile_url
    assert_equal I18n.t("users.reset.unauthorized"), flash[:alert]
    assert_no_enqueued_jobs only: FamilyResetJob
  end

  test "member can deactivate their account" do
    sign_in @member = users(:family_member)
    delete user_url(@member)

    assert_redirected_to root_url

    assert_not User.find(@member.id).active?
    assert_enqueued_with(job: UserPurgeJob, args: [ @member ])
  end

  test "admin prevented from deactivating when other users are present" do
    sign_in @admin = users(:family_admin)
    delete user_url(users(:family_member))

    assert_redirected_to settings_profile_url
    assert_equal "Admin cannot delete account while other users are present. Please delete all members first.", flash[:alert]
    assert_no_enqueued_jobs only: UserPurgeJob
    assert User.find(@admin.id).active?
  end

  test "admin can deactivate their account when they are the last user in the family" do
    sign_in @admin = users(:family_admin)
    users(:family_member).destroy

    delete user_url(@admin)

    assert_redirected_to root_url
    assert_not User.find(@admin.id).active?
    assert_enqueued_with(job: UserPurgeJob, args: [ @admin ])
  end

  test "deactivating revokes every session, API key and OAuth token of the user" do
    member = users(:family_member)
    other_session = member.sessions.create!
    api_key = ApiKey.create!(user: member, name: "Key", display_key: "deact_#{SecureRandom.hex(8)}", scopes: [ "read" ])
    app = Doorkeeper::Application.create!(name: "App", redirect_uri: "https://example.com/cb", scopes: "read")
    token = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: member.id, scopes: "read")
    member.update!(unconfirmed_email: "pending@example.com")

    sign_in member
    delete user_url(member)
    assert_redirected_to root_url

    member.reload
    assert_not member.active?
    assert_nil member.unconfirmed_email
    assert_not Session.exists?(other_session.id)
    assert_equal 0, member.sessions.count
    assert api_key.reload.revoked?
    assert token.reload.revoked?

    # The browser that deactivated is signed out
    get root_url
    assert_redirected_to new_session_url
  end

  test "a session cookie of a deactivated user no longer authenticates" do
    member = users(:family_member)
    sign_in member
    member.update_column(:active, false)

    get root_url
    assert_redirected_to new_session_url
  end

  test "a family member cannot change household settings" do
    member = users(:family_member)
    family = member.family
    sign_in member

    patch user_url(member), params: { user: {
      first_name: "Jake",
      family_attributes: { currency: "EUR", use_fiscal_months: "1", fiscal_month_start_day: 15, name: "Renamed" }
    } }

    assert_redirected_to settings_profile_url
    assert_equal I18n.t("users.update.family_settings_admin_only"), flash[:notice]
    assert_equal "Jake", member.reload.first_name
    family.reload
    assert_not_equal "EUR", family.currency
    assert_not_equal "Renamed", family.name
  end

  test "a family member saving their own preference is not told a change was refused" do
    member = users(:family_member)
    sign_in member

    patch user_url(member), params: { user: { default_period: "last_7_days", family_attributes: { id: member.family_id } } }

    assert_equal I18n.t("users.update.success"), flash[:notice]
    assert_equal "last_7_days", member.reload.default_period
  end

  test "a family admin can change household settings" do
    patch user_url(@user), params: { user: { family_attributes: { name: "New Name" } } }

    assert_equal "New Name", @user.family.reload.name
  end

  test "rejects an unknown family currency with a message instead of an error page" do
    original = @user.family.currency

    patch user_url(@user), params: { user: { family_attributes: { id: @user.family.id, currency: "XYZ" } } }

    assert_redirected_to settings_profile_url
    assert_match "currency is invalid", flash[:alert]
    assert_equal original, @user.family.reload.currency
  end

  test "rejects an unknown family time zone from the preferences page" do
    patch user_url(@user), params: { user: { redirect_to: "preferences", family_attributes: { id: @user.family.id, timezone: "Invalid/Timezone" } } }

    assert_redirected_to settings_preferences_url
    assert_match "is invalid", flash[:alert]
  end
end
