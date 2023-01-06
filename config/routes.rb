# frozen_string_literal: true

require 'sidekiq/web'
require 'sidekiq_unique_jobs/web'

Rails.application.routes.draw do
  domain_constraints =
    if !Rails.env.development?
      {
        domain: ENV.fetch('KEYGEN_DOMAIN') {
          # Get host without subdomains if domain is not explicitly set
          host = ENV.fetch('KEYGEN_HOST')
          next unless
            domains = host.downcase.strip.split('.')[-2, 2]

          domains.join('.')
        },
      }
    else
      {}
    end

  mount Sidekiq::Web, at: '/-/sidekiq'

  namespace "-" do
    post 'csp-reports', to: proc { |env|
      bytesize = env['rack.input'].size
      next [422, {}, []] if bytesize > 10.kilobytes

      payload = env['rack.input'].read
      env['rack.input'].rewind

      Rails.logger.warn "[csp-reports] CSP violation: size=#{bytesize} payload=#{payload}"

      [202, {}, []]
    }
  end

  scope module: "bin", constraints: { subdomain: %w[bin get], **domain_constraints, format: "jsonapi" } do
    version_constraint "<=1.0" do
      scope module: :v1x0 do
        get ":account_id",     constraints: { account_id: /[^\/]*/ },           to: "artifacts#index", as: "bin_artifacts"
        get ":account_id/:id", constraints: { account_id: /[^\/]*/, id: /.*/ }, to: "artifacts#show",  as: "bin_artifact"
      end
    end

    version_constraint ">=1.1" do
      get ":account_id/:release_id",     constraints: { account_id: /[^\/]+/, release_id: /[^\/]+/ },           to: "artifacts#index"
      get ":account_id/:release_id/:id", constraints: { account_id: /[^\/]+/, release_id: /[^\/]+/, id: /.*/ }, to: "artifacts#show"
    end
  end

  scope module: "stdout", constraints: { subdomain: %w[stdout], **domain_constraints, format: "jsonapi" } do
    get "unsub/:ciphertext", constraints: { ciphertext: /.*/ }, to: "subscribers#unsubscribe", as: "stdout_unsubscribe"
  end

  concern :v1 do
    get  "ping",      to: "health#general_ping"
    post "passwords", to: "passwords#reset"
    get  "profile",   to: "profiles#show"
    get  "me",        to: "profiles#me"

    resources "tokens", only: %i[index show] do
      collection do
        post "/", to: "tokens#generate"

        # FIXME(ezekg) Deprecate this route
        put  "/", to: "tokens#regenerate_current"
      end

      member do
        put    "/", to: "tokens#regenerate"
        delete "/", to: "tokens#revoke"
      end

      scope module: "tokens/relationships" do
        resource "environment", only: %i[show]
        resource "bearer", only: %i[show]
      end
    end

    resources "keys" do
      scope module: "keys/relationships" do
        resource "product", only: [:show]
        resource "policy", only: [:show]
      end
    end

    # NOTE(ezekg) By default, Rails does not allow dots inside our routes, but
    #             we want to support dots since our machines are queryable by
    #             their fingerprint attr, which can be an arbitrary string.
    resources "machines", constraints: { id: /[^\/]*/ } do
      scope module: "machines/relationships" do
        resources "processes", only: %i[index show]
        resource "environment", only: %i[show]
        resource "product", only: [:show]
        resource "group", only: [:show, :update]
        resource "license", only: [:show]
        resource "user", only: [:show]
      end
      member do
        scope "actions", module: "machines/actions" do
          post "reset-heartbeat", to: "heartbeats#reset"
          post "ping-heartbeat", to: "heartbeats#ping"
          post "reset", to: "heartbeats#reset"
          post "ping", to: "heartbeats#ping"
          post "check-out", to: "checkouts#create"
          get "check-out", to: "checkouts#show"

          scope module: :v1x0 do
            post "generate-offline-proof", to: "proofs#create"
          end
        end
      end
    end

    resources "processes" do
      scope module: "processes/relationships" do
        resource "environment", only: %i[show]
        resource "product", only: %i[show]
        resource "license", only: %i[show]
        resource "machine", only: %i[show]
      end
      member do
        scope "actions", module: "processes/actions" do
          post "ping", to: "heartbeats#ping"
        end
      end
    end

    # NOTE(ezekg) Users are queryable by email attr.
    resources "users", constraints: { id: /[^\/]*/ } do
      scope module: "users/relationships" do
        resources "second_factors", path: "second-factors", only: [:index, :show, :create, :update, :destroy]
        resources "products", only: [:index, :show]
        resources "licenses", only: [:index, :show]
        resources "machines", only: [:index, :show]
        resources "tokens", only: [:index, :show, :create]
        resource "environment", only: %i[show]
        resource "group", only: [:show, :update]
      end
      member do
        scope "actions", module: "users/actions" do
          post "update-password", to: "password#update"
          post "reset-password", to: "password#reset"
          post "ban", to: "bans#ban"
          post "unban", to: "bans#unban"
        end
      end
    end

    # NOTE(ezekg) Licenses are queryable by their key attr, which can be an
    #             arbitrary string.
    resources "licenses", constraints: { id: /[^\/]*/ } do
      scope module: "licenses/relationships" do
        resources "machines", only: [:index, :show]
        resources "tokens", only: %i[index show create]
        resource "environment", only: %i[show]
        resource "product", only: [:show]
        resource "policy", only: [:show, :update]
        resource "group", only: [:show, :update]
        resource "user", only: [:show, :update]
        resources "entitlements", only: [:index, :show] do
          collection do
            post "/", to: "entitlements#attach", as: "attach"
            delete "/", to: "entitlements#detach", as: "detach"
          end
        end
      end
      member do
        scope "actions", module: "licenses/actions" do
          get "validate", to: "validations#quick_validate_by_id"
          post "validate", to: "validations#validate_by_id"
          delete "revoke", to: "permits#revoke"
          post "renew", to: "permits#renew"
          post "suspend", to: "permits#suspend"
          post "reinstate", to: "permits#reinstate"
          post "check-in", to: "permits#check_in"
          post "increment-usage", to: "uses#increment"
          post "decrement-usage", to: "uses#decrement"
          post "reset-usage", to: "uses#reset"
          post "check-out", to: "checkouts#create"
          get "check-out", to: "checkouts#show"
        end
      end
      collection do
        scope "actions", module: "licenses/actions" do
          post "validate-key", to: "validations#validate_by_key"
        end
      end
    end

    resources "policies" do
      scope module: "policies/relationships" do
        resources "pool", only: [:index, :show], as: "keys" do
          collection do
            delete "/", to: "pool#pop", as: "pop"
          end
        end
        resources "licenses", only: [:index, :show]
        resource "environment", only: %i[show]
        resource "product", only: [:show]
        resources "entitlements", only: [:index, :show] do
          collection do
            post "/", to: "entitlements#attach", as: "attach"
            delete "/", to: "entitlements#detach", as: "detach"
          end
        end
      end
    end

    resources "products" do
      scope module: "products/relationships" do
        resources "policies", only: [:index, :show]
        resources "licenses", only: [:index, :show]
        resources "machines", only: [:index, :show]
        resources "tokens", only: [:index, :show, :create]
        resources "users", only: [:index, :show]
        resources "artifacts", constraints: { id: /.*/ }, only: [:index, :show]
        resources "platforms", only: [:index, :show]
        resources "arches", only: [:index, :show]
        resources "channels", only: [:index, :show]
        resources "releases", constraints: { id: /[^\/]*/ }, only: [:index, :show]
        resource "environment", only: %i[show]
      end
    end

    resources "releases", constraints: { id: /[^\/]*/ } do
      version_constraint "<=1.0" do
        member do
          scope "actions", module: "releases/actions" do
            scope module: :v1x0 do
              get "upgrade", to: "upgrades#check_for_upgrade_by_id"
            end
          end
        end
        collection do
          put "/", to: "releases#create", as: "upsert"

          scope "actions", module: "releases/actions" do
            scope module: :v1x0 do
              # FIXME(ezekg) This needs to take precedence over the upgrade relationship,
              #              otherwise the relationship tries to match "actions" as a
              #              release ID when hitting the root /actions/upgrade.
              get "upgrade", to: "upgrades#check_for_upgrade_by_query"
            end
          end
        end
      end

      scope module: "releases/relationships" do
        resources "entitlements", only: [:index, :show]
        resources "constraints", only: [:index, :show] do
          collection do
            post "/", to: "constraints#attach", as: "attach"
            delete "/", to: "constraints#detach", as: "detach"
          end
        end
        resources "artifacts", only: [:index, :show]
        resource "environment", only: %i[show]
        resource "upgrade", only: %i[show]
        resource "product", only: [:show]

        version_constraint "<=1.0" do
          scope module: :v1x0 do
            resource "artifact", only: [:show, :destroy], as: :v1_0_artifact do
              put :create
            end
          end
        end
      end

      member do
        scope "actions", module: "releases/actions" do
          post "publish", to: "publishings#publish"
          post "yank", to: "publishings#yank"
        end
      end
    end

    resources "artifacts", constraints: { id: /.*/ } do
      scope module: "artifacts/relationships" do
        resource "environment", only: %i[show]
      end
    end

    resources "platforms", only: [:index, :show] do
      scope module: "platforms/relationships" do
        resource "environment", only: %i[show]
      end
    end

    resources "arches", only: [:index, :show] do
      scope module: "arches/relationships" do
        resource "environment", only: %i[show]
      end
    end

    resources "channels", only: [:index, :show] do
      scope module: "channels/relationships" do
        resource "environment", only: %i[show]
      end
    end

    resources "entitlements" do
      scope module: "entitlements/relationships" do
        resource "environment", only: %i[show]
      end
    end

    resources "groups" do
      scope module: "groups/relationships" do
        resource "environment", only: %i[show]
        resources "users", only: %i[index show]
        resources "licenses", only: %i[index show]
        resources "machines", only: %i[index show]
        resources "owners", only: %i[index show] do
          collection do
            post "/", to: "owners#attach", as: "attach"
            delete "/", to: "owners#detach", as: "detach"
          end
        end
      end
    end

    resources "webhook_endpoints", path: "webhook-endpoints"
    resources "webhook_events", path: "webhook-events", only: [:index, :show, :destroy] do
      member do
        scope "actions", module: "webhook_events/actions" do
          post "retry", to: "retries#retry"
        end
      end
    end

    ee do
      resources "request_logs", path: "request-logs", only: [:index, :show]  do
        collection do
          scope "actions", module: "request_logs/actions" do
            get "count", to: "counts#count"
          end
        end
      end

      resources "event_logs", path: "event-logs", only: [:index, :show]
      resources "environments"
    end

    resources "metrics", only: [:index, :show] do
      collection do
        scope "actions", module: "metrics/actions" do
          get "count", to: "counts#count"
        end
      end
    end

    resources "analytics", only: [] do
      collection do
        scope "actions", module: "analytics/actions" do
          get "top-licenses-by-volume", to: "counts#top_licenses_by_volume"
          get "top-urls-by-volume", to: "counts#top_urls_by_volume"
          get "top-ips-by-volume", to: "counts#top_ips_by_volume"
          get "count", to: "counts#count"
        end
      end
    end

    post "search", to: "searches#search"
  end

  scope module: "api", constraints: { format: "jsonapi" } do
    namespace "v1" do
      constraints subdomain: %w[api], **domain_constraints do
        post "stripe", to: "stripe#receive_webhook"

        # Health checks
        get "health", to: "health#general_health"
        get "health/webhooks", to: "health#webhook_health"

        # Recover
        post "recover", to: "recoveries#recover"

        # Pricing
        resources "plans", only: [:index, :show]

        # Routes with :account namespace
        resources "accounts", concerns: %i[v1], except: [:index] do
          scope module: "accounts/relationships" do
            resource "billing", only: [:show, :update]
            resource "plan", only: [:show, :update]
          end
          member do
            scope "actions", module: "accounts/actions" do
              post "manage-subscription", to: "subscription#manage"
              post "pause-subscription", to: "subscription#pause"
              post "resume-subscription", to: "subscription#resume"
              post "cancel-subscription", to: "subscription#cancel"
              post "renew-subscription", to: "subscription#renew"
            end
          end
        end
      end

      # Routes without :account namespace (used via CNAMEs)
      concerns :v1
    end
  end

  %w[500 503].each do |code|
    match code, to: "errors#show", code: code.to_i, via: :all
  end

  match '*unmatched_route', to: "errors#show", code: 404, via: :all
  root to: "errors#show", code: 404, via: :all
end
