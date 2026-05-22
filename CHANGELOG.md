# Changelog

## v0.2.6 - 2026-05-22

- Added README guidance for using Ruby reports with the Logister project Insights beta, including practical metric, transaction, log, check-in, and custom attribute examples.

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
