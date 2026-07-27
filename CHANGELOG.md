# Changelog

## v0.3.1 - 2026-07-26

- Added `Logister.suppress_reporting` and `Logister.reporting_suppressed?` for recursion-safe telemetry processing, including early exits in automatic SQL and request subscribers.

## v0.3.0 - 2026-07-25

- Raised the supported runtime floor to Ruby 3.3 and refreshed the development runtime to Ruby 4.0.6, which includes current interpreter security fixes.
- Raised the Rails integration floor to patched Rails 8 releases.
- Added Ruby 3.3, 3.4, and 4.0 CI coverage plus a RubyGems advisory audit gate.
- Pinned release actions to immutable commits and removed the duplicate release dispatch path.

## v0.2.8 - 2026-06-18

- Added first-class source context configuration (`repository`, `commit_sha`, and `branch`) with `LOGISTER_*` and GitHub Actions environment variable support.
- Added `Logister.record_deployment` for posting release-to-commit deployment records to Logister.

## v0.2.7 - 2026-05-22

- Added `Logister.report_span` and opt-in Rails request span capture for request load waterfall charts.

## v0.2.6 - 2026-05-22

- Added README guidance for using Ruby reports with the Logister project Insights beta, including practical metric, transaction, log, check-in, and custom attribute examples.
- Added a tag-based release workflow that publishes the gem to RubyGems with trusted publishing and then creates or updates the matching GitHub release.

## v0.2.5 - 2026-05-21

- Added metric value/unit options to `Logister.report_metric` while keeping the existing context/tags API.
- Added per-check-in environment, release, occurred-at, trace ID, and request ID options to `Logister.report_check_in`.

## v0.2.4 - 2026-05-21

- Enriched every Ruby error report with shared runtime, deployment, breadcrumb, and dependency context, including manual `Logister.report_error` calls.
- Added structured nested exception cause data to Ruby error payloads.

## v0.2.3 - 2026-04-22

- Refined the Ruby and Rails client for Logister event delivery.
- Added richer reporting support for logs, transactions, check-ins, ActiveJob failures, breadcrumbs, and dependency context.
- Improved package metadata and docs linkage for the canonical Logister docs and self-hosted backend.
- Documented the gem as the Ruby client for the Logister backend instead of only the hosted `logister.org` service.
