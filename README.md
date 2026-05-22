# logister-ruby

`logister-ruby` is the Ruby and Rails client for sending errors, logs, metrics, transactions, and check-ins to Logister.

Install it from RubyGems as `logister-ruby`.

## Table Of Contents

- [What this gem is for](#what-this-gem-is-for)
- [Self-hosted backend](#self-hosted-backend)
- [Install From RubyGems](#install-from-rubygems)
- [Configuration](#configuration)
- [Reliability options](#reliability-options)
- [Filtering and redaction](#filtering-and-redaction)
- [Rails auto-reporting](#rails-auto-reporting)
- [Database load metrics (ActiveRecord)](#database-load-metrics-activerecord)
- [Breadcrumbs and dependencies](#breadcrumbs-and-dependencies)
- [ActiveJob error context](#activejob-error-context)
- [Manual reporting](#manual-reporting)
- [Using project Insights beta](#using-project-insights-beta)
- [Documentation](#documentation)
- [Release](#release)

## What this gem is for

Use this gem when you want a Ruby or Rails app to send telemetry into the Logister backend.

- Main Logister app: https://github.com/taimoorq/logister
- Ruby integration docs: https://docs.logister.org/integrations/ruby/
- Product docs: https://docs.logister.org/
- RubyGems package: https://rubygems.org/gems/logister-ruby

## Self-hosted backend

Use the open source Logister app repository to self-host the ingestion UI/API backend:

- App source: https://github.com/taimoorq/logister

## Install From RubyGems

With Bundler in a Rails or Ruby app:

```ruby
gem "logister-ruby"
```

Then install:

```bash
bundle install
```

Or install the gem directly from RubyGems:

```bash
gem install logister-ruby
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

  # Optional richer context hooks
  config.anonymize_ip = false
  config.max_breadcrumbs = 40
  config.max_dependencies = 20
  config.capture_sql_breadcrumbs = true
  config.sql_breadcrumb_min_duration_ms = 25.0

  config.feature_flags_resolver = lambda do |request:, user:, **|
    { new_checkout: user&.respond_to?(:beta?) && user.beta? }
  end

  config.dependency_resolver = lambda do |**|
    [] # or return [{ name:, host:, method:, status:, durationMs:, kind: }]
  end
end
```

If you are using a self-hosted Logister install, point `config.endpoint` at your own Logister host instead of `logister.org`.

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
It also attaches richer context such as trace IDs, route/response/performance info, breadcrumbs, dependency calls, and user metadata when available.
Manual `Logister.report_error` calls use the same shared enrichment path, so Ruby apps get runtime, deployment, breadcrumb, dependency, user, and nested exception cause context even when an error is reported outside the Rails middleware.

## Database load metrics (ActiveRecord)

You can capture SQL timing metrics using ActiveSupport notifications:

```ruby
Logister.configure do |config|
  config.capture_db_metrics = true
  config.db_metric_min_duration_ms = 10.0
  config.db_metric_sample_rate = 1.0
end
```

This emits metric events with `message: "db.query"` and context fields such as `duration_ms`, `name`, `sql`, and `binds_count`.

## Breadcrumbs and dependencies

You can add manual breadcrumbs and dependency calls that will be attached to captured errors:

```ruby
Logister.add_breadcrumb(
  category: "checkout",
  message: "Starting payment authorization",
  data: { order_id: 123 }
)

Logister.add_dependency(
  name: "stripe.charge",
  host: "api.stripe.com",
  method: "POST",
  status: 200,
  duration_ms: 184.7,
  kind: "http"
)
```

The gem also captures request and SQL breadcrumbs automatically in Rails.

## ActiveJob error context

Failed ActiveJob executions are auto-reported with `job` context:
- job class/id/queue/retries/schedule
- filtered job arguments (using `filter_parameters`)
- runtime/deployment metadata
- breadcrumbs/dependency calls collected during the job

## Manual reporting

```ruby
Logister.report_error(StandardError.new("Something failed"), tags: { area: "checkout" })

Logister.report_metric(
  message: "checkout.completed",
  value: 1,
  unit: "count",
  level: "info",
  context: { duration_ms: 123 },
  tags: { region: "us-east-1" }
)

Logister.report_transaction(
  name: "POST /checkout",
  duration_ms: 184.7,
  status: 200,
  context: { trace_id: "trace-123", request_id: "req-123" }
)

Logister.report_log(
  message: "payment provider timeout",
  level: "warn",
  context: { trace_id: "trace-123", request_id: "req-123", user_id: 42 }
)

Logister.report_check_in(
  slug: "nightly-reconcile",
  status: "ok",
  expected_interval_seconds: 900,
  duration_ms: 248.3,
  trace_id: "trace-123",
  request_id: "req-123"
)
```

## Using project Insights beta

The Logister project Insights tab combines Inbox, Activity, and Performance signals into live dashboard views. Ruby apps get the most useful Insights experience when every event carries stable deployment context plus a few low-cardinality custom attributes.

Use `config.environment`, `config.release`, and top-level scalar `context` values for the dimensions you want to filter by:

```ruby
Logister.configure do |config|
  config.environment = Rails.env
  config.release = ENV["RELEASE_SHA"]
  config.service = "billing-web"
end

Logister.report_metric(
  message: "queue.depth",
  value: Sidekiq::Queue.new("billing").size,
  unit: "jobs",
  context: {
    service: "billing-worker",
    queue: "billing",
    region: "us-east-1",
    tenant_tier: "enterprise"
  }
)

Logister.report_transaction(
  name: "POST /checkout",
  duration_ms: 184.7,
  status: 200,
  context: {
    service: "billing-web",
    route: "POST /checkout",
    feature_flag: "new_checkout",
    tenant_tier: "enterprise"
  }
)

Logister.report_log(
  message: "payment provider retry",
  level: "warn",
  context: {
    service: "billing-worker",
    provider: "stripe",
    queue: "billing"
  }
)

Logister.report_check_in(
  slug: "nightly-reconcile",
  status: "ok",
  expected_interval_seconds: 3600,
  duration_ms: 842.7,
  context: {
    service: "billing-worker",
    queue: "reconcile"
  }
)
```

Practical Insights recipes:

- Release validation: send `release`, then filter the Insights tab to the new release and compare errors, transaction P95, database query timing, and custom metrics.
- Queue monitoring: report metrics such as `queue.depth`, `queue.latency`, and `jobs.retry_count` with a stable `queue` context key.
- Performance triage: send transaction events with `route`, `service`, and `tenant_tier` so slow routes can be filtered beside errors and logs.
- Instrumentation audit: open Insights after deploy and confirm errors, logs, metrics, transactions, and check-ins all appear in the recent stream.

Keep dashboard dimensions stable and low-cardinality. Good custom attribute keys include `service`, `region`, `queue`, `route`, `tenant_tier`, `provider`, and `feature_flag`. Avoid raw IDs, emails, request bodies, SQL text, and per-user values as top-level Insights dimensions.

## Documentation

- Ruby integration docs: https://docs.logister.org/integrations/ruby/
- Insights beta guide: https://docs.logister.org/product/#insights-beta
- Main Logister docs: https://docs.logister.org/
- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Pull Request Template](.github/PULL_REQUEST_TEMPLATE.md)

## Release

This repo runs CI on commits and pull requests, but it does not publish to RubyGems automatically from GitHub Actions. Use Bundler's built-in release flow when you intentionally want a RubyGems release:

```bash
# 1) bump version in lib/logister/version.rb
# 2) update CHANGELOG.md
# 3) commit changes
bundle exec rake release
```

`rake release` will build the gem, create a git tag, push commits/tags, and push to RubyGems.
