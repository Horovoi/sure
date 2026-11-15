require "test_helper"
require "ostruct"

class Settings::HostingsControllerTest < ActionDispatch::IntegrationTest
  include ProviderTestHelper

  setup do
    sign_in users(:family_admin)

    @provider = mock
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(@provider)

    @provider.stubs(:healthy?).returns(true)
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(@provider)
    @provider.stubs(:usage).returns(provider_success_response(
      OpenStruct.new(
        used: 10,
        limit: 100,
        utilization: 10,
        plan: "free",
      )
    ))
  end

  test "cannot edit when self hosting is disabled" do
    @provider.stubs(:usage).returns(@usage_response)

    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get settings_hosting_url
    assert_response :forbidden

    patch settings_hosting_url, params: { setting: { onboarding_state: "invite_only" } }
    assert_response :forbidden
  end

  test "should get edit when self hosting is enabled" do
    @provider.expects(:usage).returns(@usage_response)

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
    end
  end

  test "hides the pending transactions toggle when bank connections are disabled" do
    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "input[name=?]", "setting[syncs_include_pending]", count: 0
      assert_select "input[name=?]", "setting[auto_sync_enabled]"
    end
  end

  test "shows the pending transactions toggle when bank connections are enabled" do
    enable_bank_connections

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "input[name=?]", "setting[syncs_include_pending]"
    end
  end

  test "only monobank on: the Plaid pending toggle is hidden and its value ignored" do
    enable_bank_connections(:monobank)
    Setting.syncs_include_pending = true

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "input[name=?]", "setting[syncs_include_pending]", count: 0

      patch settings_hosting_url, params: { setting: { syncs_include_pending: "0" } }
      assert Setting.syncs_include_pending
    end
  end

  test "can update settings when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { twelve_data_api_key: "1234567890" } }

      assert_equal "1234567890", Setting.twelve_data_api_key
    end
  end

  test "can update onboarding state when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { onboarding_state: "invite_only" } }

      assert_equal "invite_only", Setting.onboarding_state
      assert Setting.require_invite_for_signup

      patch settings_hosting_url, params: { setting: { onboarding_state: "closed" } }

      assert_equal "closed", Setting.onboarding_state
      refute Setting.require_invite_for_signup
    end
  end

  test "can update openai access token when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_access_token: "token" } }

      assert_equal "token", Setting.openai_access_token
    end
  end

  test "can update openai uri base and model together when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_uri_base: "https://api.example.com/v1", openai_model: "gpt-4" } }

      assert_equal "https://api.example.com/v1", Setting.openai_uri_base
      assert_equal "gpt-4", Setting.openai_model
    end
  end

  test "cannot update openai uri base without model when self hosting is enabled" do
    with_self_hosting do
      Setting.openai_model = ""

      patch settings_hosting_url, params: { setting: { openai_uri_base: "https://api.example.com/v1" } }

      assert_response :unprocessable_entity
      assert_match(/OpenAI model is required/, flash[:alert])
      assert_nil Setting.openai_uri_base
    end
  end

  test "can update openai model alone when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_model: "gpt-4" } }

      assert_equal "gpt-4", Setting.openai_model
    end
  end

  test "cannot clear openai model when custom uri base is set" do
    with_self_hosting do
      Setting.openai_uri_base = "https://api.example.com/v1"
      Setting.openai_model = "gpt-4"

      patch settings_hosting_url, params: { setting: { openai_model: "" } }

      assert_response :unprocessable_entity
      assert_match(/OpenAI model is required/, flash[:alert])
      assert_equal "gpt-4", Setting.openai_model
    end
  end

  test "can clear data cache when self hosting is enabled" do
    account = accounts(:investment)
    holding = account.holdings.first
    exchange_rate = exchange_rates(:one)
    security_price = holding.security.prices.first
    account_balance = account.balances.create!(date: Date.current, balance: 1000, currency: "USD")

    with_self_hosting do
      perform_enqueued_jobs(only: DataCacheClearJob) do
        delete clear_cache_settings_hosting_url
      end
    end

    assert_redirected_to settings_hosting_url
    assert_equal I18n.t("settings.hostings.clear_cache.cache_cleared"), flash[:notice]

    assert_not ExchangeRate.exists?(exchange_rate.id)
    assert_not Security::Price.exists?(security_price.id)
    assert_not Holding.exists?(holding.id)
    assert_not Balance.exists?(account_balance.id)
  end

  test "can clear data only when admin" do
    with_self_hosting do
      sign_in users(:family_member)

      assert_no_enqueued_jobs do
        delete clear_cache_settings_hosting_url
      end

      assert_redirected_to settings_hosting_url
      assert_equal I18n.t("settings.hostings.not_authorized"), flash[:alert]
    end
  end

  test "can update scheduled jobs start time" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { scheduled_jobs_start_time: "04:00" } }

      assert_redirected_to settings_hosting_url
      assert_equal "04:00", Setting.scheduled_jobs_start_time
    end
  end

  test "can update scheduled jobs timezone" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { scheduled_jobs_timezone: "America/New_York" } }

      assert_redirected_to settings_hosting_url
      assert_equal "America/New_York", Setting.scheduled_jobs_timezone
    end
  end

  test "can update individual job times" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { data_cleaner_time: "05:30" } }

      assert_redirected_to settings_hosting_url
      assert_equal "05:30", Setting.data_cleaner_time
    end
  end

  test "rejects invalid scheduled jobs time" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { scheduled_jobs_start_time: "invalid" } }

      assert_redirected_to settings_hosting_url
      assert_equal I18n.t("settings.hostings.update.invalid_sync_time"), flash[:alert]
    end
  end

  test "can reset scheduled jobs to defaults" do
    with_self_hosting do
      Setting.data_cleaner_time = "06:00"
      Setting.security_health_check_time = "07:00"

      post reset_scheduled_jobs_settings_hosting_url

      assert_redirected_to settings_hosting_url
      assert_nil Setting.data_cleaner_time
      assert_nil Setting.security_health_check_time
    end
  end

  test "cannot reset scheduled jobs when not admin" do
    with_self_hosting do
      sign_in users(:family_member)

      Setting.data_cleaner_time = "06:00"

      post reset_scheduled_jobs_settings_hosting_url

      assert_redirected_to settings_hosting_url
      assert_equal I18n.t("settings.hostings.not_authorized"), flash[:alert]
      assert_equal "06:00", Setting.data_cleaner_time
    end
  end

  test "an admin turns the MCP switch off and on" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { mcp_enabled: "0" } }

      assert_redirected_to settings_hosting_url
      assert_equal false, Setting.mcp_enabled

      patch settings_hosting_url, params: { setting: { mcp_enabled: "1" } }

      assert_redirected_to settings_hosting_url
      assert_equal true, Setting.mcp_enabled
    end
  ensure
    Setting.mcp_enabled = true
  end

  test "a non-admin cannot change the MCP switch" do
    with_self_hosting do
      sign_in users(:family_member)

      patch settings_hosting_url, params: { setting: { mcp_enabled: "0" } }

      assert_redirected_to settings_hosting_url
      assert_equal I18n.t("settings.hostings.not_authorized"), flash[:alert]
      assert_equal true, Setting.mcp_enabled
    end
  end

  test "the MCP section shows the switch and whether the env file opts in" do
    with_self_hosting do
      with_env_overrides(MCP_API_TOKEN: "secret-token", MCP_USER_EMAIL: users(:family_admin).email) do
        get settings_hosting_url

        assert_response :success
        assert_select "input[name=?]", "setting[mcp_enabled]"
        assert_select "#mcp-status", text: /#{I18n.t("settings.hostings.mcp_settings.token_set")}/
        assert_select "#mcp-status", text: /#{Regexp.escape(users(:family_admin).email)}/
        refute_match "secret-token", response.body
      end

      with_env_overrides(MCP_API_TOKEN: nil, MCP_USER_EMAIL: nil) do
        get settings_hosting_url

        assert_select "#mcp-status", text: /#{I18n.t("settings.hostings.mcp_settings.token_not_set")}/
      end
    end
  end

  test "a failed update renders the page with its provider sections" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_uri_base: "https://example.com/v1", openai_model: "" } }

      assert_response :unprocessable_entity
      assert_select "input[name=?]", "setting[mcp_enabled]"
    end
  end

  test "the scheduled jobs section lists each job with its last and next run" do
    stub_scheduled_jobs(worker_beat: Time.current)

    with_self_hosting do
      get settings_hosting_url
      assert_response :success

      assert_select "#scheduled-jobs-status table" do
        assert_select "th[scope=row]", text: /Hourly sync/
        assert_select "th[scope=row]", text: /Daily full backup.*Not scheduled/m
      end
      assert_select "#scheduled-jobs-status", text: /No worker is running/, count: 0
    end
  end

  test "the scheduled jobs section warns when no worker is alive" do
    stub_scheduled_jobs(worker_beat: 10.minutes.ago)

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "#scheduled-jobs-status", text: /No worker is running/
    end
  end

  test "the page still renders when Redis is down" do
    Sidekiq::Cron::Job.stubs(:all).raises(RedisClient::CannotConnectError, "connection refused")

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "#scheduled-jobs-status", text: /Job status is unavailable/
      assert_select "#scheduled-jobs-status table", count: 0
    end
  end

  test "a super admin sees the link to the Sidekiq cron page" do
    stub_scheduled_jobs(worker_beat: Time.current)
    sign_in users(:sure_support_staff)

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "a#sidekiq-cron-link[href=?]", "/sidekiq/cron"
    end
  end

  test "an admin who is not a super admin does not see the Sidekiq link" do
    stub_scheduled_jobs(worker_beat: Time.current)

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "a#sidekiq-cron-link", count: 0
    end
  end

  test "a member does not see the Sidekiq link" do
    stub_scheduled_jobs(worker_beat: Time.current)
    sign_in users(:family_member)

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
      assert_select "#scheduled-jobs-status table"
      assert_select "a#sidekiq-cron-link", count: 0
    end
  end

  private
    def stub_scheduled_jobs(worker_beat:)
      hourly = stub(name: "sync_hourly", cron: "0 * * * *", last_enqueue_time: 30.minutes.ago, enabled?: true)
      Sidekiq::Cron::Job.stubs(:all).returns([ hourly ])
      Sidekiq::ProcessSet.stubs(:new).returns([ { "beat" => worker_beat.to_f } ])
    end
end
