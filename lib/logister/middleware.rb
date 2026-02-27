require 'socket'

module Logister
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue StandardError => e
      Logister.report_error(
        e,
        context: {
          request: build_request_context(env),
          app:     build_app_context
        }
      )
      raise
    end

    private

    def build_request_context(env)
      ctx = {
        id:     env['action_dispatch.request_id'],
        path:   env['PATH_INFO'],
        method: env['REQUEST_METHOD'],
        ip:     remote_ip(env),
        user_agent: env['HTTP_USER_AGENT']
      }

      # Params — available if ActionDispatch has already parsed them
      if (params = env['action_dispatch.request.parameters'])
        ctx[:params] = filter_params(params)
      end

      ctx.compact
    end

    def build_app_context
      ctx = {
        ruby:     RUBY_VERSION,
        hostname: hostname
      }
      ctx[:rails] = Rails::VERSION::STRING if defined?(Rails::VERSION)
      ctx
    end

    # Respect X-Forwarded-For set by proxies, fall back to REMOTE_ADDR
    def remote_ip(env)
      forwarded = env['HTTP_X_FORWARDED_FOR'].to_s.split(',').first&.strip
      forwarded.nil? || forwarded.empty? ? env['REMOTE_ADDR'] : forwarded
    end

    # Remove sensitive parameter values the same way Rails does
    SENSITIVE_PARAMS = %w[password password_confirmation token secret api_key
                          credit_card cvv ssn].freeze

    def filter_params(params)
      params.each_with_object({}) do |(k, v), h|
        h[k] = SENSITIVE_PARAMS.any? { |s| k.to_s.downcase.include?(s) } ? '[FILTERED]' : v
      end
    rescue StandardError
      {}
    end

    def hostname
      Socket.gethostname
    rescue StandardError
      'unknown'
    end
  end
end
