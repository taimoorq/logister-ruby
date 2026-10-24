require_relative "context_helpers"
require_relative "context_store"

module Logister
  class Middleware
    FILTERED_HEADER_PLACEHOLDER = Logister::Redaction::REDACTED

    # Only these request headers are captured. Add more with
    # `config.capture_headers`; the shared sensitive-key rule still applies to
    # every captured header name, and values are scrubbed for credentials.
    CAPTURED_HEADERS = %w[
      accept accept-encoding accept-language cache-control content-length content-type
      dnt host origin referer user-agent via
      traceparent tracestate x-request-id x-amzn-trace-id
      x-b3-traceid x-b3-spanid x-b3-parentspanid x-b3-sampled
      x-datadog-trace-id x-datadog-parent-id x-datadog-sampling-priority
      x-forwarded-for x-forwarded-host x-forwarded-proto x-forwarded-port x-real-ip
      sec-fetch-dest sec-fetch-mode sec-fetch-site sec-fetch-user
      sec-ch-ua sec-ch-ua-mobile sec-ch-ua-platform upgrade-insecure-requests
    ].freeze
    IP_HEADERS = %w[x-forwarded-for x-real-ip].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      trace_context = begin_request(env)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      [status, with_request_id_header(headers, trace_context), body]
    rescue StandardError => e
      report_exception(e, env, started_at)
      raise
    ensure
      end_request(env, trace_context)
    end

    private

    def begin_request(env)
      Logister::ContextStore.reset_request_scope!
      trace_context = Logister::TraceContext.from_headers(
        traceparent: env["HTTP_TRACEPARENT"], request_id: env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      )
      Logister::ContextStore.trace_context = trace_context
      env["logister.trace_context"] = trace_context
      trace_context
    rescue StandardError => e
      Logister.log_internal_error("middleware setup", e)
      nil
    end

    def with_request_id_header(headers, trace_context)
      return headers unless trace_context

      headers.merge("x-request-id" => trace_context.request_id)
    rescue StandardError => e
      Logister.log_internal_error("middleware response header", e)
      headers
    end

    # Context building and reporting run in their own rescue so a telemetry
    # failure can never replace the application's exception.
    def report_exception(error, env, started_at)
      request = build_request(env)
      request_context = build_request_context(request, env, error: error, started_at: started_at)

      Logister.report_error(
        error,
        context: request_context
      )
    rescue StandardError => e
      Logister.log_internal_error("middleware error report", e)
      nil
    end

    def end_request(env, trace_context)
      Logister::ContextStore.clear_request_summary(trace_context&.request_id)
      request_id = env["action_dispatch.request_id"]
      Logister::ContextStore.clear_request_summary(request_id)
      Logister::ContextStore.reset_request_scope!
    rescue StandardError => e
      Logister.log_internal_error("middleware cleanup", e)
      nil
    end

    # Rails apps get ActionDispatch::Request, including filtered parameters.
    # Plain Rack apps get Rack::Request; parameters are then omitted because no
    # host filter is configured, and the redacted URL still records the query.
    def build_request(env)
      return ActionDispatch::Request.new(env) if defined?(ActionDispatch::Request)

      require "rack/request" unless defined?(Rack::Request)
      Rack::Request.new(env)
    end

    def build_request_context(request, env, error:, started_at:)
      request_id = env["action_dispatch.request_id"].to_s.presence
      path = request.path.to_s
      method = request.request_method.to_s
      params = request_params(request)
      headers = extract_headers(env)
      referer = Logister::Redaction.redact_url(request.referer.to_s.presence || headers["Referer"])
      url = Logister::Redaction.redact_url(request_url(request))
      http_version = env["HTTP_VERSION"].to_s.presence || env["SERVER_PROTOCOL"].to_s.presence
      rails_action = rails_action_name(params)
      response_status = response_status_for(error)
      duration_ms = elapsed_duration_ms(started_at)
      current_user = current_user(env)
      user_context = Logister::ContextHelpers.user_context_for(current_user)
      request_summary = Logister::ContextStore.request_summary(request_id) || {}
      dependencies = collected_dependencies(request: request, env: env)
      breadcrumbs = Logister::ContextStore.breadcrumbs
      feature_flags = Logister::ContextHelpers.resolve_feature_flags(request: request, env: env, user: current_user)
      trace_context = Logister::ContextHelpers.trace_context(headers: headers, env: env)
      client_ip = Logister::ContextHelpers.anonymize_ip(request.ip.to_s.presence)

      base_context = {
        request_id: request_id,
        path: path,
        method: method,
        clientIp: client_ip,
        headers: headers,
        httpMethod: method,
        httpVersion: http_version,
        params: params,
        railsAction: rails_action,
        referer: referer,
        requestId: request_id,
        url: url,
        response: {
          status: request_summary[:status] || response_status,
          contentType: request.content_type.to_s.presence,
          format: request_summary[:format] || request_format(request),
          durationMs: duration_ms
        }.compact,
        route: {
          name: env["action_dispatch.route_name"].to_s.presence,
          pathTemplate: route_path_template(env),
          controller: request_summary[:controller] || route_value(params, "controller"),
          action: request_summary[:action] || route_value(params, "action")
        }.compact,
        performance: {
          dbRuntimeMs: request_summary[:dbRuntimeMs],
          viewRuntimeMs: request_summary[:viewRuntimeMs],
          allocations: request_summary[:allocations]
        }.compact,
        dependencyCalls: dependencies.presence,
        breadcrumbs: breadcrumbs.presence,
        request: {
          clientIp: client_ip,
          headers: headers,
          httpMethod: method,
          httpVersion: http_version,
          params: params,
          railsAction: rails_action,
          referer: referer,
          requestId: request_id,
          url: url
        }.compact
      }.compact

      Logister::ContextHelpers.compact_deep(
        base_context
          .merge(trace_context)
          .merge(feature_flags)
          .merge(user_context)
          .merge(Logister::ContextHelpers.runtime_context)
          .merge(Logister::ContextHelpers.deployment_context)
      )
    end

    def request_params(request)
      return {} unless request.respond_to?(:filtered_parameters)

      request.filtered_parameters.to_h
    rescue StandardError
      {}
    end

    def request_url(request)
      url = request.respond_to?(:original_url) ? request.original_url : request.url
      url.to_s.presence
    rescue StandardError
      nil
    end

    def request_format(request)
      return nil unless request.respond_to?(:format)

      request.format&.to_s.presence
    rescue StandardError
      nil
    end

    def rails_action_name(params)
      return nil unless params.is_a?(Hash)

      controller_name = params["controller"].to_s.presence || params[:controller].to_s.presence
      action_name = params["action"].to_s.presence || params[:action].to_s.presence
      return nil if controller_name.blank? || action_name.blank?

      "#{controller_name}##{action_name}"
    end

    def extract_headers(env)
      allowed = captured_header_names
      headers = {}

      env.each do |key, value|
        next unless value.is_a?(String)

        header_name = rack_env_to_header_name(key)
        next unless header_name && allowed.include?(header_name.downcase)

        headers[header_name] = filter_header_value(header_name, value)
      end

      headers.sort.to_h
    end

    def captured_header_names
      extra = Array(Logister.configuration.capture_headers).map { |name| name.to_s.downcase.tr("_", "-") }
      CAPTURED_HEADERS | extra
    rescue StandardError
      CAPTURED_HEADERS
    end

    def rack_env_to_header_name(key)
      if key.start_with?("HTTP_")
        key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-")
      elsif key == "CONTENT_TYPE"
        "Content-Type"
      elsif key == "CONTENT_LENGTH"
        "Content-Length"
      end
    end

    def filter_header_value(name, value)
      normalized = name.to_s.downcase
      return FILTERED_HEADER_PLACEHOLDER if Logister::Redaction.sensitive_key?(normalized)
      return anonymize_ip_list(value) if IP_HEADERS.include?(normalized)
      return Logister::Redaction.redact_url(value) if normalized == "referer"

      value
    end

    def anonymize_ip_list(value)
      value.split(",").map { |ip| Logister::ContextHelpers.anonymize_ip(ip.strip) }.compact.join(", ")
    end

    def current_user(env)
      controller = env["action_controller.instance"]
      return nil unless controller

      if controller.respond_to?(:current_user)
        controller.public_send(:current_user)
      elsif controller.respond_to?(:current_user, true)
        controller.send(:current_user)
      end
    rescue StandardError
      nil
    end

    def collected_dependencies(request:, env:)
      custom = Logister::ContextHelpers.resolve_dependency_context(request: request, env: env).fetch(:dependencyCalls, [])
      manual = Logister::ContextStore.dependencies
      Array(manual) + Array(custom)
    end

    def response_status_for(error)
      return 500 unless defined?(ActionDispatch::ExceptionWrapper)

      ActionDispatch::ExceptionWrapper.status_code_for_exception(error.class.name)
    rescue StandardError
      500
    end

    def elapsed_duration_ms(started_at)
      return nil unless started_at

      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(2)
    rescue StandardError
      nil
    end

    def route_path_template(env)
      pattern = env["action_dispatch.route_uri_pattern"]
      return pattern.spec.to_s.presence if pattern.respond_to?(:spec)

      pattern.to_s.presence
    rescue StandardError
      nil
    end

    def route_value(params, key)
      return nil unless params.is_a?(Hash)

      params[key].to_s.presence || params[key.to_sym].to_s.presence
    end
  end
end
