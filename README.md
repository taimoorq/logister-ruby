# logister-ruby

`logister-ruby` sends Ruby and Rails errors, logs, metrics, transactions, spans, and scheduled-job check-ins to Logister. Rails apps also get automatic reporting for unhandled requests and failed Active Job executions.

Install it from RubyGems as `logister-ruby`.

Requires Ruby 3.3 or newer and Active Support 8.x.

## Quick start

Before you start, create a project in Logister and generate a project API key under **Project settings → API keys**.

Add the gem and generate a Rails initializer:

```bash
bundle add logister-ruby
bin/rails generate logister:install
```

Store configuration in environment variables:

```bash
export LOGISTER_API_KEY="<project-api-key>"
export LOGISTER_ENDPOINT="https://logister.example.com/api/v1/ingest_events"
export LOGISTER_SERVICE="checkout-web"
export LOGISTER_RELEASE="$(git rev-parse --short HEAD)"
```

Start Rails, then send a safe test event from `bin/rails console`:

```ruby
Logister.report_error(
  RuntimeError.new("README test error"),
  context: { component: "checkout" },
  fingerprint: "readme-test-error"
)
Logister.flush
```

Open the project inbox and confirm that **README test error** appears. A `401` response usually means the API key or endpoint is wrong; see the [Ruby integration guide](https://logister.org/docs/integrations/ruby/) for troubleshooting.

## Table Of Contents

- [Quick start](#quick-start)
- [What this gem is for](#what-this-gem-is-for)
- [Package Links](#package-links)
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
- [Using project Insights](#using-project-insights)
- [GitHub source context and deployments](#github-source-context-and-deployments)
- [Documentation](#documentation)
- [Development](#development)
- [Release](#release)

## What this gem is for

Use this gem when a Ruby process should send telemetry to a hosted or self-hosted Logister server. It is an ingest client, not the Logister server itself.

- Main Logister app: https://github.com/taimoorq/logister
- Ruby integration docs: https://logister.org/docs/integrations/ruby/
- Product docs: https://logister.org/docs/
- RubyGems package: https://rubygems.org/gems/logister-ruby

## Package Links

- RubyGems package: https://rubygems.org/gems/logister-ruby
- GitHub releases: https://github.com/taimoorq/logister-ruby/releases
- Source repository: https://github.com/taimoorq/logister-ruby
- Integration docs: https://logister.org/docs/integrations/ruby/

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
  config.capture_request_spans = true

  config.feature_flags_resolver = lambda do |request:, user:, **|
    { new_checkout: user&.respond_to?(:beta?) && user.beta? }
  end

  config.dependency_resolver = lambda do |**|
    [] # or return [{ name:, host:, method:, status:, durationMs:, kind: }]
  end
end
```

If you are using a self-hosted Logister install, point `config.endpoint` at your own Logister host instead of `logister.org`.

Keep `LOGISTER_API_KEY` in your deployment secret store. Project API keys are write-only ingest credentials, but exposing one still lets another party submit unwanted telemetry to the project.

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

Use scoped suppression around work that handles or forwards telemetry. Every manual reporter and automatic Rails subscriber returns without publishing while the scope is active, and nested scopes restore the previous state even when the block raises:

```ruby
Logister.suppress_reporting do
  TelemetryMirror.call(event)
end
```

This is especially important when a Rails application reports into a Logister project hosted by that same application. Keep suppression narrow so failures outside the telemetry-processing boundary remain observable.

## Rails auto-reporting

If Rails is present, the gem installs middleware that reports unhandled exceptions automatically. It attaches trace IDs, route and response data, performance context, breadcrumbs, dependency calls, and user metadata when available.

Set `config.capture_request_spans = true` to emit root `server` spans for request-load waterfall charts while keeping the existing transaction events. Manual `Logister.report_error` calls use the same enrichment path, including runtime, deployment, breadcrumb, dependency, user, and nested-exception context.

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

Logister.report_span(
  name: "render checkout",
  duration_ms: 82.1,
  trace_id: "trace-123",
  parent_span_id: "span-root",
  kind: "render",
  status: "ok",
  context: { route: "POST /checkout" }
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

## Using project Insights

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
- Instrumentation audit: open Insights after deploy and confirm errors, logs, metrics, transactions, spans, and check-ins all appear in the recent stream.

Keep dashboard dimensions stable and low-cardinality. Good custom attribute keys include `service`, `region`, `queue`, `route`, `tenant_tier`, `provider`, and `feature_flag`. Avoid raw IDs, emails, request bodies, SQL text, and per-user values as top-level Insights dimensions.

## GitHub source context and deployments

When a Logister project is connected to a GitHub repository, set source context once so error frames and releases can resolve to the exact commit:

```ruby
Logister.configure do |config|
  config.repository = ENV["LOGISTER_REPOSITORY"] || ENV["GITHUB_REPOSITORY"]
  config.commit_sha = ENV["LOGISTER_COMMIT_SHA"] || ENV["GITHUB_SHA"]
  config.branch = ENV["LOGISTER_BRANCH"] || ENV["GITHUB_REF_NAME"]
end
```

CI/CD can also record the release-to-commit mapping directly:

```ruby
Logister.record_deployment(
  release: "checkout@2026.06.18",
  environment: "production",
  repository: "acme/checkout",
  commit_sha: "4f8c2d1a9b7e6c5d4a3b2c1d0e9f8a7b6c5d4e3f",
  branch: "main",
  workflow_run_url: "https://github.com/acme/checkout/actions/runs/123"
)
```

`config.deployment_endpoint` defaults to the configured ingest endpoint with `/ingest_events` replaced by `/deployments`. Set `LOGISTER_DEPLOYMENT_ENDPOINT` when your deployment endpoint cannot be derived from `LOGISTER_ENDPOINT`.

## Documentation

- Ruby integration docs: https://logister.org/docs/integrations/ruby/
- Insights guide: https://logister.org/docs/product/#insights
- Main Logister docs: https://logister.org/docs/
- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Pull Request Template](.github/PULL_REQUEST_TEMPLATE.md)

## Development

```bash
bundle install
bundle-audit check --update
bundle exec rake test
bundle exec rake build
```

## Release

`lib/logister/version.rb` is the package version source of truth. Update it and `CHANGELOG.md` together. After CI passes on `main`, the release-from-main workflow creates a matching `vX.Y.Z` tag and dispatches the release workflow.

```bash
git tag -a vX.Y.Z -m "Release logister-ruby vX.Y.Z"
git push origin vX.Y.Z
```

The release workflow verifies tag/version parity, audits and tests the package, builds the gem, publishes to RubyGems with trusted publishing, and only then creates the GitHub Release. RubyGems versions are immutable; corrections need a new patch version.

Before tag releases can publish the gem, configure a RubyGems trusted publisher for:

- GitHub owner: `taimoorq`
- Repository: `logister-ruby`
- Workflow file: `.github/workflows/release.yml`
- Environment: leave blank unless you also add a GitHub release environment to the workflow

Verify both release surfaces before calling a release complete:

```bash
curl -fsSL https://rubygems.org/api/v2/rubygems/logister-ruby/versions/X.Y.Z.json | jq '{number,ruby_version,sha}'
gh release view vX.Y.Z
```
