# git.cr

A pure Crystal implementation of the Git client protocol. Clone and pull repositories over HTTP(S), SSH, or local paths — no `libgit2`, no shell-out to `git`.

```crystal
require "git"

# Clone
Git::Client.clone("https://github.com/crystal-lang/crystal.git", "/tmp/crystal")

# Pull (fast-forward only; raises NonFastForwardError if upstream diverged)
Git::Client.pull("/tmp/crystal")

# Sync (fast-forward if possible, hard-reset otherwise)
Git::Client.sync("/tmp/crystal")

# Reset to remote HEAD unconditionally (e.g. after upstream force-push)
Git::Client.reset("/tmp/crystal")
```

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  git:
    github: threez/git.cr
```

Then run `shards install`.

## Capabilities

### Transport

All four transports (HTTP, HTTPS, SSH, `file://`) support clone, pull, reset, sync,
side-band-64k multiplexing, have/want negotiation, shallow clone, and protocol v2.

- **Authentication (Basic/Bearer)** — HTTP and HTTPS only; SSH uses agent forwarding.
- **Push** — not supported on any transport.

### Pack format

Supported: pack v2, OFS\_DELTA, REF\_DELTA, thin packs, pack index v2 (.idx) generation,
commit-graph file for fast ancestry checks.

### Object types

All four git object types are parsed: Blob, Tree, Commit, Tag (annotated).

### Working tree

Supported: full checkout on clone, incremental checkout on pull/reset, file
create/modify/delete, executable bit, symlinks, submodules, Git LFS on HTTP/HTTPS/SSH
and `file://` remotes (the last requires `.lfsconfig`).

### Merge strategies

Supported: fast-forward.

### Repository state

Supported: read remote URL from `.git/config`, read/write HEAD, packed-refs, branch
refs, remote-tracking refs, FETCH\_HEAD, ORIG\_HEAD, multi-pack and loose object store.

## Architecture

See [doc/architecture.md](doc/architecture.md) for a detailed breakdown of the layers and data flows.

## Requirements

- Crystal >= 1.18.0
- zlib (system library, linked via Crystal's `lib_z`)
- `git-upload-pack` on `PATH` (SSH and file:// transports)
- `ssh` on `PATH` (SSH transport only)

## Development

```bash
# Run all tests
make spec

# Integration tests only (require git on PATH)
make integration

# Format check + lint + tests
make
```

Integration tests create temporary bare repositories under `spec/tmp/`.

## Known Limitations

- **`.gitattributes` processing** — line-ending conversion and filter drivers are not applied during checkout.
- **Large pack offset table** — packs larger than 2 GB (requiring the 64-bit offset table in `.idx` v2) are not supported.
- **Merge strategies** — only fast-forward merges are supported; merge commits and rebase are not.
- **Reflogs** — `.git/logs/` is not read or written.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Add tests for your change
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create a Pull Request

## Contributors

- [Vincent Landgraf](https://github.com/threez) - creator and maintainer

## License

MIT
