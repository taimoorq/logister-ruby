# logister-ruby

`logister-ruby` sends application errors and custom metrics to `logister.org`.

## Install

```ruby
gem "logister-ruby"
```

Then generate an initializer in Rails:

```bash
bin/rails generate logister:install
```

## Configuration

```ruby
Logister.configure do |config|
  config.api_key = ENV.fetch("LOGISTER_API_KEY")
  config.endpoint = "https://logister.org/api/v1/ingest_events"
  config.environment = Rails.env
  config.service = Rails.application.class.module_parent_name.underscore
  config.release = ENV["RELEASE_SHA"]
end
```

## Reliability options

```ruby
Logister.configure do |config|
  config.async = true
  config.queue_size = 1000
  config.max_retries = 3
  config.retry_base_interval = 0.5
end
```

## Filtering and redaction

```ruby
Logister.configure do |config|
  config.ignore_environments = ["development", "test"]
  config.ignore_exceptions = ["ActiveRecord::RecordNotFound"]
  config.ignore_paths = [/health/, "/up"]

  config.before_notify = lambda do |payload|
    payload[:context]&.delete("authorization")
    payload
  end
end
```

## Rails auto-reporting

If Rails is present, the gem installs middleware that reports unhandled exceptions automatically.

## Manual reporting

```ruby
Logister.report_error(StandardError.new("Something failed"), tags: { area: "checkout" })

Logister.report_metric(
  message: "checkout.completed",
  level: "info",
  context: { duration_ms: 123 },
  tags: { region: "us-east-1" }
)
```
