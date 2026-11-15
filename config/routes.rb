require "sidekiq/web"
require "sidekiq/cron/web"

Rails.application.routes.draw do
  resources :coinbase_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end
  # CoinStats routes
  resources :coinstats_items, only: [ :index, :new, :create, :update, :destroy ] do
    collection do
      post :link_wallet
    end
    member do
      post :sync
    end
  end

  resources :enable_banking_items, only: [ :new, :create, :update, :destroy ] do
    collection do
      get :callback
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end
    member do
      post :sync
      get :select_bank
      post :authorize
      post :reauthorize
      get :setup_accounts
      post :complete_account_setup
      post :new_connection
    end
  end
  use_doorkeeper
  # MFA routes
  resource :mfa, controller: "mfa", only: [ :new, :create ] do
    get :verify
    post :verify, to: "mfa#verify_code"
    delete :disable
  end

  # Component previews for development (bin/dev) and the test suite. Production and the
  # staging copy (RAILS_ENV=production) do not mount them.
  mount Lookbook::Engine, at: "/design-system" unless Rails.env.production?

  # Queue dashboard. Development mounts it open. Everywhere else (production, staging,
  # test) the route exists only for a signed-in, active super admin; see
  # app/constraints/super_admin_constraint.rb. Signed-out visitors get a 404.
  if Rails.env.development?
    mount Sidekiq::Web => "/sidekiq"
  else
    constraints SuperAdminConstraint.new do
      mount Sidekiq::Web => "/sidekiq"
    end
  end

  # AI chats
  resources :chats do
    resources :messages, only: :create

    member do
      post :retry
    end
  end

  resources :family_exports, only: %i[new create index destroy] do
    member do
      get :download
    end
  end

  patch "dashboard/preferences", to: "pages#update_preferences"

  resource :current_session, only: %i[update]

  resource :registration, only: %i[new create]
  resources :sessions, only: %i[index new create destroy]
  match "/auth/:provider/callback", to: "sessions#openid_connect", via: %i[get post]
  match "/auth/failure", to: "sessions#failure", via: %i[get post]
  get "/auth/logout/callback", to: "sessions#post_logout"
  resource :oidc_account, only: [] do
    get :link, on: :collection
    post :create_link, on: :collection
    get :new_user, on: :collection
    post :create_user, on: :collection
  end
  resource :password_reset, only: %i[new create edit update]
  resource :password, only: %i[edit update]
  resource :email_confirmation, only: :new

  resources :users, only: %i[update destroy] do
    delete :reset, on: :member
    delete :reset_with_sample_data, on: :member
    patch :rule_prompt_settings, on: :member
    get :resend_confirmation_email, on: :member
  end

  resource :onboarding, only: :show do
    collection do
      get :preferences
      get :goals
    end
  end

  namespace :settings do
    resource :profile, only: [ :show, :destroy ]
    resource :preferences, only: :show
    resource :budgeting, only: :show
    resource :hosting, only: %i[show update] do
      delete :clear_cache, on: :collection
      post :reset_scheduled_jobs, on: :collection
    end
    resource :security, only: :show
    resources :sso_identities, only: :destroy
    resource :api_key, only: [ :show, :new, :create, :destroy ]
    resource :ai_prompts, only: :show
    resource :llm_usage, only: :show
    resource :guides, only: :show
    resource :bank_sync, only: :show, controller: "bank_sync"
    resource :providers, only: %i[show update]
  end

  # w1-fx debug-log: super-admin debug event log (Settings > Debug, no nav link)
  namespace :settings do
    resource :debug, only: :show
  end

  resources :tags, except: :show do
    resources :deletions, only: %i[new create], module: :tag
    delete :destroy_all, on: :collection
  end

  namespace :category do
    resource :dropdown, only: :show
  end

  # --- DS pickers (w1-ds): tag picker of a transaction row, tag save of the edit drawer ---
  namespace :tag do
    resource :dropdown, only: :show
  end
  patch "transactions/:id/tags", to: "transactions#update_tags", as: :tags_transaction
  # --- end DS pickers ---

  # --- Category merge (w2-rules) ---
  get "categories/merge", to: "categories#merge", as: :merge_categories
  post "categories/merge", to: "categories#perform_merge", as: :perform_merge_categories
  # --- end category merge ---

  resources :categories, except: :show do
    resources :deletions, only: %i[new create], module: :category

    post :bootstrap, on: :collection
    delete :destroy_all, on: :collection
  end

  resources :reports, only: %i[index] do
    patch :update_preferences, on: :collection
    get :export_transactions, on: :collection
    get :google_sheets_instructions, on: :collection
    get :print, on: :collection
  end

  resources :budgets, only: %i[index show edit update], param: :month_year do
    get :picker, on: :collection

    # w1-budrec: copy the previous budget into an empty month
    post :copy_previous, on: :member

    resources :budget_categories, only: %i[index show update]

    # w3-envelope: move money between envelopes of one budget
    resources :budget_categories, only: [] do
      post :move, on: :collection
    end
  end

  # --- Savings goals (w2-goals): goals, their lifecycle, spending and pledges ---
  resources :goals do
    member do
      patch :pause
      patch :resume
      patch :complete
      patch :archive
      patch :unarchive
      patch :reopen
      # Spending from a goal (goal-spending). Two actions on one path, not one action
      # branching on the verb: HEAD routes like GET but is not request.get?. A goal can be
      # spent from more than once, so the write is a POST.
      get :consume
      post :consume, action: :record_consumption, as: nil
    end

    # Pledges (goal-pledges): delete cancels the pledge, renew extends its window
    resources :pledges, only: %i[new create destroy], controller: "goal_pledges" do
      member do
        patch :renew
      end
    end
  end
  # --- end savings goals ---

  resources :family_merchants, only: %i[index new create edit update destroy] do
    collection do
      get :merge
      post :perform_merge
    end
  end

  # --- Merchant page (w2-rules): after the block above, so /family_merchants/new and /merge are not read as an :id ---
  resources :family_merchants, only: :show do
    delete :clear_filter, on: :member
  end
  # --- end merchant page ---

  resources :transfers, only: %i[new create destroy show update]

  # --- w2-transfers transfer-match-policy: review page for pending transfer auto-matches ---
  resources :auto_matches, only: :index do
    member do
      patch :confirm
      patch :reject
    end
    collection do
      patch :bulk_update
    end
  end
  # --- end w2-transfers transfer-match-policy ---

  # --- w2-transfers custom-exchange-rate: one rate lookup for every form (nearest-rate rule) ---
  get :exchange_rate, to: "exchange_rates#show"
  # --- end w2-transfers custom-exchange-rate ---

  # --- w2-transfers default-account: the account new entries start in ---
  resources :accounts, only: [] do
    member do
      patch :set_default
      patch :remove_default
    end
  end
  # --- end w2-transfers default-account ---

  resources :imports, only: %i[index new show create update destroy] do
    member do
      post :publish
      put :revert
      put :apply_template
      post :retry_processing
    end

    resource :upload, only: %i[show update], module: :import
    resource :configuration, only: %i[show update], module: :import
    resource :clean, only: :show, module: :import
    resource :confirm, only: :show, module: :import

    resources :rows, only: %i[show update], module: :import
    resources :mappings, only: :update, module: :import
  end

  resources :holdings, only: %i[index new show update destroy] do
    member do
      post :unlock_cost_basis
    end
  end
  resources :trades, only: %i[show new create update destroy]
  resources :valuations, only: %i[show new create update destroy] do
    post :confirm_create, on: :collection
    post :confirm_update, on: :member
  end

  namespace :transactions do
    resource :bulk_deletion, only: :create
    resource :bulk_update, only: %i[new create]
  end

  # --- Categorize wizard (w2-rules) ---
  namespace :transactions do
    resource :categorize, only: %i[show create] do
      patch :assign_entry, on: :collection
      get :preview_rule, on: :collection
    end
  end
  # --- end categorize wizard ---

  # --- Transaction name suggestions (w2-rules): before resources, so the name is not taken for a :id ---
  get "transactions/name_suggestions", to: "transactions#name_suggestions", as: :name_suggestions_transactions
  # --- end transaction name suggestions ---

  resources :transactions, only: %i[index new create show update destroy] do
    resource :transfer_match, only: %i[new create destroy] # destroy: w2-transfers transfer-hints "Not a transfer"
    resource :category, only: :update, controller: :transaction_categories

    collection do
      delete :clear_filter
      patch :update_preferences
    end

    member do
      get :convert_to_trade
      post :create_trade_from_transaction
      post :mark_as_recurring
      post :mark_as_subscription
      post :merge_duplicate
      post :dismiss_duplicate
    end
  end

  # w2-subs: put back a generated subscription charge that a real charge replaced
  resources :transactions, only: [] do
    member do
      post :restore_subscription_charge
    end
  end

  resources :subscriptions, only: %i[index new create show edit update destroy] do
    collection do
      get :calendar
      get :suggestions
      post :detect
      post :approve_all_suggestions
      post :dismiss_all_suggestions
    end

    member do
      post :toggle_status
      post :record_transaction
      post :skip_occurrence
      post :approve_suggestion
      post :dismiss_suggestion
      post :restore_suggestion
    end

    # w1-budrec: detection toggle and manual recurring rows on Subscriptions
    patch :update_detection_settings, on: :collection
    post :make_subscription, on: :member

    # w1-budrec: turn the subscriptions iCal feed on, give it a new link, or turn it off
    post :enable_feed, on: :collection
    post :reset_feed, on: :collection
    delete :disable_feed, on: :collection
  end

  # w1-budrec: subscriptions iCal feed, read by calendar apps without a session
  get "feeds/subscriptions/:token.ics", to: "subscription_feeds#show", as: :subscriptions_feed,
    format: false, constraints: { token: /[A-Za-z0-9_-]+/ }

  resources :subscription_services, only: [ :index ] do
    collection do
      get :uncached
    end
    member do
      post :cache_icon
    end
  end

  resources :accountable_sparklines, only: :show, param: :accountable_type

  direct :entry do |entry, options|
    if entry.new_record?
      route_for entry.entryable_name.pluralize, options
    else
      route_for entry.entryable_name, entry, options
    end
  end

  resources :rules, except: :show do
    member do
      get :confirm
      post :apply
    end

    collection do
      delete :destroy_all
      get :confirm_all
      post :apply_all
      # ordered-rule-runner: save the run order
      patch :reorder
    end
  end

  resources :accounts, only: %i[index new show destroy], shallow: true do
    member do
      post :sync
      get :sparkline
      patch :toggle_active
      get :select_provider
      get :confirm_unlink
      delete :unlink
      delete :clear_filter
    end

    collection do
      post :sync_all
    end
  end

  # Convenience routes for polymorphic paths
  # Example: account_path(Account.new(accountable: Depository.new)) => /depositories/123
  direct :edit_account do |model, options|
    route_for "edit_#{model.accountable_name}", model, options
  end

  resources :depositories, only: %i[new create edit update]
  resources :investments, only: %i[new create edit update]
  resources :properties, only: %i[new create edit update] do
    member do
      get :balances
      patch :update_balances

      get :address
      patch :update_address
    end
  end
  resources :vehicles, only: %i[new create edit update]
  resources :credit_cards, only: %i[new create edit update]
  resources :loans, only: %i[new create edit update]
  resources :cryptos, only: %i[new create edit update]
  resources :other_assets, only: %i[new create edit update]
  resources :other_liabilities, only: %i[new create edit update]

  resources :securities, only: :index

  resources :invite_codes, only: %i[index create destroy]

  resources :invitations, only: [ :new, :create, :destroy ] do
    get :accept, on: :member
    post :confirm, on: :member
  end

  # API routes
  namespace :api do
    namespace :v1 do
      # Authentication endpoints
      post "auth/signup", to: "auth#signup"
      post "auth/login", to: "auth#login"
      post "auth/refresh", to: "auth#refresh"

      # Production API endpoints
      resources :accounts, only: [ :index, :show ]
      resources :categories, only: [ :index, :show ]
      resources :merchants, only: %i[index show]
      resources :tags, only: %i[index show create update destroy]

      resources :transactions, only: [ :index, :show, :create, :update, :destroy ]
      resources :holdings, only: [ :index, :show ]
      resources :trades, only: [ :index, :show, :create, :update, :destroy ]
      resources :valuations, only: [ :show, :create, :update ]
      resources :imports, only: [ :index, :show, :create ]
      delete "users/reset", to: "users#reset"
      delete "users/me", to: "users#destroy"
      resource :usage, only: [ :show ], controller: :usage
      post :sync, to: "sync#create"

      resources :chats, only: [ :index, :show, :create, :update, :destroy ] do
        resources :messages, only: [ :create ] do
          post :retry, on: :collection
        end
      end

      # Test routes for API controller testing (only available in test environment)
      if Rails.env.test?
        get "test", to: "test#index"
        get "test_not_found", to: "test#not_found"
        get "test_family_access", to: "test#family_access"
        get "test_scope_required", to: "test#scope_required"
        get "test_multiple_scopes_required", to: "test#multiple_scopes_required"
      end
    end
  end

  # --- MCP (w1-mcp): protocol 2026-07-28, POST only; GET and DELETE answer 405 ---
  match "mcp", to: "mcp#handle", via: %i[post get delete]
  # --- end MCP ---

  # --- AI tool-call audit (w1-mcp): Settings > Advanced > AI tool calls, read-only, admins only ---
  namespace :settings do
    resources :ai_tool_audits, only: :index
  end
  # --- end AI tool-call audit ---

  # --- Claude chat (w2-ai): the Claude card on Settings > AI (loaded lazily) and the chat model select ---
  namespace :settings do
    resource :ai_chat, only: %i[show update]
  end
  # --- end Claude chat ---



  resources :currencies, only: %i[show]

  resources :impersonation_sessions, only: [ :create ] do
    post :join, on: :collection
    delete :leave, on: :collection

    member do
      put :approve
      put :reject
      put :complete
    end
  end

  resources :plaid_items, only: %i[new edit create destroy] do
    collection do
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
    end
  end

  resources :lunchflow_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  namespace :webhooks do
    post "plaid"
    post "plaid_eu"
  end

  get "redis-configuration-error", to: "pages#redis_configuration_error"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "pwa#service_worker", as: :pwa_service_worker, defaults: { format: :js }
  get "manifest" => "pwa#manifest", as: :pwa_manifest, defaults: { format: :json }

  get "imports/:import_id/upload/sample_csv", to: "import/uploads#sample_csv", as: :import_upload_sample_csv

  get "privacy", to: redirect("about:blank")
  get "terms", to: redirect("about:blank")

  # Admin namespace for super admin functionality
  namespace :admin do
    resources :sso_providers do
      member do
        patch :toggle
        post :test_connection
      end
    end
    resources :users, only: [ :index, :update ]
  end

  # Legacy redirects
  get "calendar", to: redirect("/subscriptions/calendar")

  # Defines the root path route ("/")
  root "pages#dashboard"
end
