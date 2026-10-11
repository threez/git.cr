# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Pinned the `ameba` dev dependency to `~> 1.7.0` (previously unpinned) and
  upgraded the vendored copy to 1.7.0.
- Standardized `.github/workflows/ci.yml` on the shared two-job template
  (`lint` and `test`), pinning Crystal to 1.20.2, adding shard caching, an
  explicit `crystal tool format --check` step, and an explicit compile check,
  replacing the previous ad-hoc `make` / `make spec` invocations pinned to
  Crystal 1.18.
- Bumped `.github/workflows/pages.yml`'s Crystal version pin to 1.20.2 to
  match the CI workflow.

### Fixed

- Resolved all ameba 1.7.0 lint findings: redundant `nil` in control
  expressions, trailing `rescue` modifiers in specs, and a useless variable
  assignment in `Git::Repository::LockFile.write`.
