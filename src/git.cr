require "./git/error"
require "./git/file_system"
require "./git/file_system/file_handle"
require "./git/file_system/local"
require "./git/file_system/guarded"
require "./git/file_system/memory"
require "./git/transport/credentials"
require "./git/object/id"
require "./git/protocol/pkt_line/type"
require "./git/protocol/pkt_line/writer"
require "./git/protocol/pkt_line/reader"
require "./git/transport/url"
require "./git/protocol/capability"
require "./git/pack/object_type"
require "./git/object/blob_source"
require "./git/pack/inflate"
require "./git/pack/crc32"
require "./git/pack/scanner"
require "./git/pack/delta"
require "./git/pack/resolver"
require "./git/pack/index_writer"
require "./git/object/commit"
require "./git/object/tree"
require "./git/object/tag"
require "./git/lfs/pointer"
require "./git/lfs/client"
require "./git/worktree/diff"
require "./git/worktree/checkout"
require "./git/worktree/applier"
require "./git/transport/base"
require "./git/transport/pipe"
require "./git/transport/http"
require "./git/transport/ssh"
require "./git/transport/file"
require "./git/protocol/progress"
require "./git/protocol/sideband"
require "./git/protocol/session"
require "./git/protocol/v1"
require "./git/protocol/v2"
require "./git/protocol/negotiator"
require "./git/pack/file"
require "./git/repository"
require "./git/repository/ref"
require "./git/repository/config"
require "./git/repository/lock_file"
require "./git/pack/index"
require "./git/object/store"
require "./git/commit_graph"
require "./git/commit_graph/file"
require "./git/commit_graph/chain"
require "./git/repository/submodule"
require "./git/client"

# A pure-Crystal implementation of the Git client protocol.
# Supports cloning and pulling over HTTPS, HTTP, SSH, and `file://` transports.
#
# The four top-level methods cover the common programmatic use-cases:
#
# ```
# # Clone once
# repo = Git.clone("https://github.com/example/repo.git", "/tmp/repo")
#
# # Bring an existing clone up to date (fast-forward only)
# repo = Git.pull("/tmp/repo")
#
# # Overwrite local state with whatever the remote has (force-push safe)
# repo = Git.reset("/tmp/repo")
# ```
#
# For the `git_dir:` option (separate git directory) use `Client.clone` directly.
module Git
  VERSION = "0.1.0"

  # Parses a 40-character hex string into an `Object::Id`. Shorthand for `Object::Id.from_hex(hex)`.
  def self.oid(hex : String) : Object::Id
    Object::Id.from_hex(hex)
  end

  # Parses *url* into a `Transport::RemoteURL`. Shorthand for `Transport::RemoteURL.parse(url)`.
  def self.remote(url : String) : Transport::RemoteURL
    Transport::RemoteURL.parse(url)
  end

  # Returns a Bearer token credential. Shorthand for `Transport::Credentials.bearer(token)`.
  def self.bearer(token : String) : Transport::Credentials
    Transport::Credentials.bearer(token)
  end

  # Returns a Basic auth credential. Shorthand for `Transport::Credentials.basic(user, password)`.
  def self.basic(username : String, password : String) : Transport::Credentials
    Transport::Credentials.basic(username, password)
  end

  # Returns an unconfined `FileSystem::Local` rooted at *path*. Use for paths
  # that are already trusted (e.g. a known `.git/` directory).
  def self.fs(path : String) : FileSystem::Local
    FileSystem::Local.new(path)
  end

  # Returns a `FileSystem::Guarded` rooted at *path*, which rejects any access
  # outside that directory and refuses to follow symlinks. Use for untrusted
  # content such as working-tree checkouts from remote repositories.
  def self.safe_fs(path : String) : FileSystem::Guarded
    FileSystem::Guarded.new(path)
  end

  # Returns an in-memory `FileSystem::Memory` rooted at *root*. Useful for
  # tests that need a filesystem without touching disk.
  def self.memory_fs(root : String = "") : FileSystem::Memory
    FileSystem::Memory.new(root)
  end

  # Clones the repository at *url* into the local directory *into*.
  # Returns the initialised `Repository` on success.
  #
  # ```
  # repo = Git.clone("https://github.com/example/repo.git", "/srv/code/myapp")
  # repo = Git.clone("git@github.com:example/repo.git", "/srv/code/myapp",
  #   credentials: Git.bearer(ENV["GITHUB_TOKEN"]))
  # repo = Git.clone("https://github.com/example/big.git", "/tmp/big",
  #   branch: "v2", depth: 1)
  # ```
  #
  # ### Parameters
  #
  # *url* — Remote repository URL. Supported schemes:
  # - `https://` / `http://` — Smart HTTP (protocol v2 preferred, v1 fallback).
  # - `git@host:path` / `ssh://` — SSH, using the system `ssh` binary.
  # - `file:///absolute/path` — Local bare repository via the git file protocol.
  #
  # *into* — Path of the working-tree directory to create. The directory must
  # not already contain a `.git` entry. Parent directories are created
  # automatically when absent.
  #
  # *branch* — Branch or tag to check out after the clone. Defaults to `"HEAD"`,
  # which lets the remote decide (its default branch). Pass a bare branch name
  # such as `"main"` or `"release/2"`, or a tag name such as `"v1.0"`. When
  # a tag is given the repository is left in detached HEAD state.
  #
  # *on_progress* — Optional `Protocol::ProgressCallback` invoked once per completed
  # progress line that the remote sends (e.g. "Counting objects: 100%"). Use
  # this to drive a progress bar or log verbosity. The callback runs on the
  # calling fiber. Pass `nil` (the default) to discard progress output.
  # Example:
  # ```
  # Git.clone(url, into,
  #   on_progress: ->(msg : Git::Protocol::ProgressMessage) {
  #     print "\r#{msg.task}: #{msg.percent}%" if msg.percent
  #   })
  # ```
  #
  # *lfs* — When `true` (default), Git LFS pointer files are resolved to their
  # actual content immediately after checkout. Set to `false` to skip LFS
  # downloads; the working tree will then contain raw pointer files instead of
  # the large blobs. Requires the remote to expose an LFS batch API endpoint.
  #
  # *submodules* — When `true` (default), registered submodules are cloned
  # recursively after the main checkout. Set to `false` to skip submodule
  # initialisation, e.g. when you only need the top-level tree.
  #
  # *depth* — Limits the fetch to the last *depth* commits of history
  # (shallow clone). `nil` (default) fetches the full history. A value of `1`
  # fetches only the tip commit, which minimises download size at the cost of
  # losing history. Shallow clones can be deepened later with `pull`.
  #
  # *credentials* — Authentication credentials for private repositories.
  # Use `Git.bearer(token)` for personal-access tokens (GitHub, GitLab,
  # Gitea, …) and `Git.basic(user, password)` for Basic auth. Pass `nil`
  # (the default) for public repositories or when SSH agent forwarding provides
  # authentication. Credentials are sent only over authenticated transports;
  # they are never written to disk.
  def self.clone(url : String, into : String, branch : String = "HEAD",
                 on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                 submodules : Bool = true, depth : Int32? = nil,
                 credentials : Transport::Credentials? = nil) : Repository
    Client.clone(url, safe_fs(into), branch, on_progress, lfs, submodules, depth, credentials)
  end

  # :ditto:
  def self.clone(url : String, into : FileSystem, branch : String = "HEAD",
                 on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                 submodules : Bool = true, depth : Int32? = nil,
                 credentials : Transport::Credentials? = nil) : Repository
    Client.clone(url, into, branch, on_progress, lfs, submodules, depth, credentials)
  end

  # Fetches the latest commits from origin and fast-forward merges the tracked
  # branch in the repository at *path*. Returns the updated `Repository`.
  #
  # Raises `NonFastForwardError` when the remote history has diverged from the
  # local branch (e.g. after an upstream force-push). Use `reset` or `sync`
  # when a non-fast-forward update is acceptable.
  #
  # ```
  # repo = Git.pull("/srv/code/myapp")
  # repo = Git.pull("/srv/code/myapp", branch: "staging")
  # ```
  #
  # ### Parameters
  #
  # *path* — Working-tree root of an existing local clone (the directory that
  # contains the `.git` entry). The repository must have been initialised with
  # a configured `origin` remote (all clones created by `Git.clone` satisfy
  # this requirement).
  #
  # *branch* — Branch to update. Defaults to `"HEAD"`, which resolves to
  # whichever branch the repository currently has checked out. Pass an explicit
  # name to update a branch other than the current one.
  #
  # *on_progress* — Optional `Protocol::ProgressCallback`; see `clone` for details.
  #
  # *lfs* — When `true` (default), newly-added LFS pointer files are resolved
  # to their actual content after the merge. Set to `false` to skip LFS downloads.
  #
  # *submodules* — When `true` (default), submodule references that changed
  # between the old and new tip are updated (new submodules cloned, existing
  # ones reset to the recorded commit). Set to `false` to leave submodules
  # untouched.
  #
  # *credentials* — Authentication credentials; see `clone` for details.
  def self.pull(path : String, branch : String = "HEAD",
                on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                submodules : Bool = true, credentials : Transport::Credentials? = nil) : Repository
    Client.pull(safe_fs(path), branch, on_progress, lfs, submodules, credentials)
  end

  # :ditto:
  def self.pull(path : FileSystem, branch : String = "HEAD",
                on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                submodules : Bool = true, credentials : Transport::Credentials? = nil) : Repository
    Client.pull(path, branch, on_progress, lfs, submodules, credentials)
  end

  # Fetches the latest commits from origin and hard-resets the local branch and
  # working tree to match, regardless of ancestry. Returns the updated `Repository`.
  #
  # Equivalent to running `git fetch && git reset --hard origin/<branch>`. Use
  # this instead of `pull` when the upstream may have been force-pushed, or when
  # you want to discard any local divergence unconditionally.
  # `ORIG_HEAD` is written before the reset so the previous tip can be recovered.
  #
  # ```
  # repo = Git.reset("/srv/code/myapp")
  # ```
  #
  # ### Parameters
  #
  # *path* — Working-tree root of an existing local clone; see `pull` for details.
  #
  # *branch* — Branch to reset. Defaults to `"HEAD"` (current branch).
  #
  # *on_progress* — Optional `Protocol::ProgressCallback`; see `clone` for details.
  #
  # *lfs* — When `true` (default), LFS pointers in the new tree are resolved.
  # Set to `false` to skip LFS downloads.
  #
  # *submodules* — When `true` (default), submodules are updated to match the
  # new tree. Set to `false` to leave submodules untouched.
  #
  # *credentials* — Authentication credentials; see `clone` for details.
  def self.reset(path : String, branch : String = "HEAD",
                 on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                 submodules : Bool = true, credentials : Transport::Credentials? = nil) : Repository
    Client.reset(safe_fs(path), branch, on_progress, lfs, submodules, credentials)
  end

  # :ditto:
  def self.reset(path : FileSystem, branch : String = "HEAD",
                 on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                 submodules : Bool = true, credentials : Transport::Credentials? = nil) : Repository
    Client.reset(path, branch, on_progress, lfs, submodules, credentials)
  end

  # Fetches and applies the latest remote state unconditionally: fast-forwards
  # when the remote is a descendant of the local tip, and hard-resets otherwise.
  # Returns the updated `Repository`.
  #
  # This is the "I just want local to match remote, no questions asked" method.
  # It never raises `NonFastForwardError`. Internally it delegates to `reset`.
  #
  # ```
  # repo = Git.sync("/srv/code/myapp")
  # ```
  #
  # ### Parameters
  #
  # *path* — Working-tree root of an existing local clone; see `pull` for details.
  #
  # *branch* — Branch to synchronise. Defaults to `"HEAD"` (current branch).
  #
  # *on_progress* — Optional `Protocol::ProgressCallback`; see `clone` for details.
  #
  # *lfs* — When `true` (default), LFS pointers in the new tree are resolved.
  # Set to `false` to skip LFS downloads.
  #
  # *submodules* — When `true` (default), submodules are updated to match the
  # new tree. Set to `false` to leave submodules untouched.
  #
  # *credentials* — Authentication credentials; see `clone` for details.
  def self.sync(path : String, branch : String = "HEAD",
                on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                submodules : Bool = true, credentials : Transport::Credentials? = nil) : Repository
    Client.sync(safe_fs(path), branch, on_progress, lfs, submodules, credentials)
  end

  # :ditto:
  def self.sync(path : FileSystem, branch : String = "HEAD",
                on_progress : Protocol::ProgressCallback? = nil, lfs : Bool = true,
                submodules : Bool = true, credentials : Transport::Credentials? = nil) : Repository
    Client.sync(path, branch, on_progress, lfs, submodules, credentials)
  end
end
