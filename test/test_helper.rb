ENV["RACK_ENV"] = "test"
ENV["RAILS_ENV"] = "test"

require "minitest/autorun"
require "stringio"
require "logger"
require "action_dispatch"
require "logister"

class Minitest::Test
  def setup
    Logister.configure do |config|
      config.api_key = "test-token"
      config.endpoint = "https://example.com/api/v1/ingest_events"
      config.environment = "test"
      config.service = "logister-ruby-test"
      config.release = "test-release"
      config.enabled = true
      config.async = false
      config.logger = Logger.new(StringIO.new)
      config.ignore_exceptions = []
      config.ignore_environments = []
      config.ignore_paths = []
      config.before_notify = nil
      config.capture_db_metrics = false
      config.feature_flags_resolver = nil
      config.dependency_resolver = nil
      config.anonymize_ip = false
    end

    Logister::ContextStore.reset_request_scope!
    Logister.reporter.clear_user if Logister.respond_to?(:reporter)
  end

  def teardown
    Logister.shutdown
    Logister::ContextStore.reset_request_scope!
    Thread.current[:logister_user] = nil
  end
end
