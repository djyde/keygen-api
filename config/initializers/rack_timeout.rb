middleware = Rails.application.config.middleware

middleware.insert_before Rack::Attack, Rack::Timeout