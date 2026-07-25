# Logister Ruby SDK Agent Notes

This is a public gem repository. Never commit credentials, private telemetry,
customer data, or local Bundler configuration.

## Dependency maintenance

- `lib/logister/version.rb` is the package-version source of truth.
- `logister-ruby.gemspec` owns the Ruby floor and runtime dependency ranges;
  `.ruby-version` owns the maintainer toolchain.
- Keep the gemspec, lockfile, and CI compatible with the current Ruby floor.
  CI currently covers Ruby 3.3, 3.4, and 4.0.
- Keep Bundler and GitHub Actions Dependabot updates enabled. Pin Actions to
  full commit SHAs and retain a readable version comment.

## Verification

Run before handoff or release:

```bash
bundle install
bundle-audit check --update
bundle exec rake test
bundle exec rake build
```

## Release contract

- Update `lib/logister/version.rb` and `CHANGELOG.md` together.
- Merging a new version to `main` runs CI, creates `vX.Y.Z`, and explicitly
  dispatches `release.yml`. Keep the explicit dispatch because tags pushed with
  `GITHUB_TOKEN` do not start tag-push workflows.
- The release must verify tag/gem parity, test, audit, build, publish through
  RubyGems trusted publishing, and only then create the GitHub Release.
- RubyGems versions are immutable. Never reuse an accepted version.
- Verify the required Ruby version as well as the published version:

```bash
curl -fsSL https://rubygems.org/api/v2/rubygems/logister-ruby/versions/X.Y.Z.json | jq '{number,ruby_version,sha}'
gh release view vX.Y.Z
```
