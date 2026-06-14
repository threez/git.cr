require "../spec_helper"
require "file_utils"

# Integration tests for Git::Client.clone and Git::Client.pull.
# Requires git to be installed. Skipped automatically if git is unavailable.

FIXTURE_BARE_REPO   = File.join(__DIR__, "../fixtures/test_repo.git")
FIXTURE_LINEAR_REPO = File.join(__DIR__, "../fixtures/linear_history.git")
FIXTURE_BRANCH_REPO = File.join(__DIR__, "../fixtures/multi_branch.git")
FIXTURE_BINARY_REPO = File.join(__DIR__, "../fixtures/binary_content.git")

private def git_available? : Bool
  Process.find_executable("git") != nil
end

# Generic lazy fixture builder: initialises a src repo, yields for population,
# then clones it bare to *path* and removes the src.
private def ensure_fixture(path : String, & : String ->) : Nil
  return if Dir.exists?(path)
  src = spec_tmp("crystal-git-fixture")
  Dir.mkdir_p(src)
  run_git(src, "init", "-b", "main")
  run_git(src, "config", "user.email", "test@example.com")
  run_git(src, "config", "user.name", "Test")
  yield src
  Dir.mkdir_p(File.dirname(path))
  run_git(src, "clone", "--bare", src, path)
  FileUtils.rm_rf(src)
end

private def ensure_fixture_repo : Nil
  ensure_fixture(FIXTURE_BARE_REPO) do |src|
    File.write(File.join(src, "README.md"), "hello from crystal-git\n")
    Dir.mkdir_p(File.join(src, "src"))
    File.write(File.join(src, "src", "main.cr"), "puts \"hello\"\n")
    run_git(src, "add", ".")
    run_git(src, "commit", "-m", "Initial commit")
  end
end

private def ensure_linear_history_repo : Nil
  ensure_fixture(FIXTURE_LINEAR_REPO) do |src|
    Dir.mkdir_p(File.join(src, "data"))
    20.times do |i|
      n = (i + 1).to_s.rjust(2, '0')
      File.write(File.join(src, "data", "file#{n}.txt"),
        "# File #{n}\n\nLine 1\nLine 2\nLine 3\nEntry #{n}\n")
      changelog = File.join(src, "CHANGELOG.md")
      File.open(changelog, "a") { |io| io.print("## v#{n}\n\nRelease #{n}.\n\n") }
      run_git(src, "add", ".")
      run_git(src, "commit", "-m", "Commit #{n}")
    end
  end
end

private def ensure_multi_branch_repo : Nil
  ensure_fixture(FIXTURE_BRANCH_REPO) do |src|
    # C1 — shared root
    File.write(File.join(src, "README.md"), "multi-branch fixture\n")
    run_git(src, "add", ".")
    run_git(src, "commit", "-m", "Initial commit")

    # feature branch from C1
    run_git(src, "checkout", "-b", "feature")
    Dir.mkdir_p(File.join(src, "feature"))
    File.write(File.join(src, "feature", "widget.cr"), "class Widget; end\n")
    run_git(src, "add", ".")
    run_git(src, "commit", "-m", "Add widget")
    File.write(File.join(src, "feature", "gadget.cr"), "class Gadget; end\n")
    run_git(src, "add", ".")
    run_git(src, "commit", "-m", "Add gadget")

    # back to main for two more commits
    run_git(src, "checkout", "main")
    Dir.mkdir_p(File.join(src, "lib"))
    File.write(File.join(src, "lib", "core.cr"), "module Core; end\n")
    run_git(src, "add", ".")
    run_git(src, "commit", "-m", "Add core")
    File.write(File.join(src, "lib", "util.cr"), "module Util; end\n")
    run_git(src, "add", ".")
    run_git(src, "commit", "-m", "Add util")
  end
end

private def ensure_binary_content_repo : Nil
  ensure_fixture(FIXTURE_BINARY_REPO) do |src|
    Dir.mkdir_p(File.join(src, "assets"))
    File.open(File.join(src, "assets", "data.bin"), "wb") do |io|
      io.write(Bytes.new(256, &.to_u8))
    end
    run_git(src, "add", ".")
    run_git(src, "commit", "-m", "Add binary asset")
  end
end

# Adds a new file commit to a bare repo by cloning to a temp dir and pushing back.
private def add_commit_to_bare(bare_path : String, filename : String, content : String) : Nil
  tmp = spec_tmp("crystal-git-add")
  run_git(SPEC_TMP, "clone", bare_path, tmp)
  run_git(tmp, "config", "user.email", "test@example.com")
  run_git(tmp, "config", "user.name", "Test")
  File.write(File.join(tmp, filename), content)
  run_git(tmp, "add", filename)
  run_git(tmp, "commit", "-m", "Add #{filename}")
  run_git(tmp, "push", "origin", "main")
  FileUtils.rm_rf(tmp)
end

# Simulates a force-push by cloning to a temp dir, creating an orphan commit
# that replaces history, then force-pushing back.
# Rewrites the bare repo's history with an orphan commit containing a unique
# force.txt. Returns the content written so callers can assert against it.
private def force_push_bare(bare_path : String) : String
  content = "force-pushed-#{Random::Secure.hex(4)}\n"
  tmp = spec_tmp("crystal-git-force")
  run_git(SPEC_TMP, "clone", bare_path, tmp)
  run_git(tmp, "config", "user.email", "test@example.com")
  run_git(tmp, "config", "user.name", "Test")
  run_git(tmp, "checkout", "--orphan", "new-root")
  run_git(tmp, "rm", "-rf", ".")
  File.write(File.join(tmp, "force.txt"), content)
  run_git(tmp, "add", "force.txt")
  run_git(tmp, "commit", "-m", "Force-pushed root")
  run_git(tmp, "push", "--force", "origin", "new-root:main")
  FileUtils.rm_rf(tmp)
  content
end

private def run_git(dir : String, *args : String) : Nil
  proc = Process.new("git", args: args.to_a, chdir: dir,
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  status = proc.wait
  raise "git #{args.join(" ")} failed in #{dir}" unless status.success?
end

# ---------------------------------------------------------------------------
# Basic clone + pull
# ---------------------------------------------------------------------------

describe "Git::Client.clone (integration)", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_fixture_repo
  end

  it "clones a local bare repo via file:// URL" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-clone")
    begin
      Git::Client.clone("file://#{FIXTURE_BARE_REPO}", Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "README.md")).should be_true
      File.read(File.join(clone_dir, "README.md")).should eq("hello from crystal-git\n")
      File.exists?(File.join(clone_dir, "src", "main.cr")).should be_true
      File.exists?(File.join(clone_dir, ".git", "packed-refs")).should be_true
      File.exists?(File.join(clone_dir, ".git", "HEAD")).should be_true
      Dir.glob(File.join(clone_dir, ".git", "objects", "pack", "*.idx")).should_not be_empty
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "delivers at least one done:true ProgressMessage via on_progress callback" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-progress")
    begin
      received = [] of Git::Protocol::ProgressMessage
      Git::Client.clone("file://#{FIXTURE_BARE_REPO}", Git.safe_fs(clone_dir),
        on_progress: ->(msg : Git::Protocol::ProgressMessage) { received << msg })
      received.any?(&.done?).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

PULL_BARE_REPO = spec_tmp("crystal-git-pull-bare") + ".git"

describe "Git::Client.pull (integration)", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_fixture_repo
    run_git(SPEC_TMP, "clone", "--bare", FIXTURE_BARE_REPO, PULL_BARE_REPO) unless Dir.exists?(PULL_BARE_REPO)
  end

  it "pulls a new commit and writes the new file" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-pull")
    begin
      Git::Client.clone("file://#{PULL_BARE_REPO}", Git.safe_fs(clone_dir))
      add_commit_to_bare(PULL_BARE_REPO, "newfile.txt", "world\n")
      Git::Client.pull(Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "newfile.txt")).should be_true
      File.read(File.join(clone_dir, "newfile.txt")).should eq("world\n")
      File.exists?(File.join(clone_dir, "README.md")).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "returns immediately when already up-to-date" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-uptodate")
    begin
      Git::Client.clone("file://#{PULL_BARE_REPO}", Git.safe_fs(clone_dir))
      Git::Client.pull(Git.safe_fs(clone_dir))
      File.exists?(File.join(clone_dir, "README.md")).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# Linear history — exercises delta-compressed pack objects
# ---------------------------------------------------------------------------

describe "Git::Client.clone — linear history (delta objects)", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_linear_history_repo
  end

  it "clones a 20-commit repo and verifies the final changelog" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-linear")
    begin
      Git::Client.clone("file://#{FIXTURE_LINEAR_REPO}", Git.safe_fs(clone_dir))
      File.exists?(File.join(clone_dir, "CHANGELOG.md")).should be_true
      File.read(File.join(clone_dir, "CHANGELOG.md")).should contain("## v20")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "resolves all 20 data files from delta-compressed objects" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-linear2")
    begin
      Git::Client.clone("file://#{FIXTURE_LINEAR_REPO}", Git.safe_fs(clone_dir))
      data_files = Dir.glob(File.join(clone_dir, "data", "*.txt"))
      data_files.size.should eq(20)
      File.read(File.join(clone_dir, "data", "file20.txt")).should contain("Entry 20")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# Multi-branch — exercises branch-specific clone
# ---------------------------------------------------------------------------

describe "Git::Client.clone — multi-branch", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_multi_branch_repo
  end

  it "clones main branch and does not include feature-only files" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-main")
    begin
      Git::Client.clone("file://#{FIXTURE_BRANCH_REPO}", Git.safe_fs(clone_dir), branch: "main")
      File.exists?(File.join(clone_dir, "README.md")).should be_true
      File.exists?(File.join(clone_dir, "lib", "core.cr")).should be_true
      File.exists?(File.join(clone_dir, "lib", "util.cr")).should be_true
      File.exists?(File.join(clone_dir, "feature", "widget.cr")).should be_false
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "clones feature branch and includes feature-only files" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-feature")
    begin
      Git::Client.clone("file://#{FIXTURE_BRANCH_REPO}", Git.safe_fs(clone_dir), branch: "feature")
      File.exists?(File.join(clone_dir, "README.md")).should be_true
      File.exists?(File.join(clone_dir, "feature", "widget.cr")).should be_true
      File.exists?(File.join(clone_dir, "feature", "gadget.cr")).should be_true
      File.exists?(File.join(clone_dir, "lib", "core.cr")).should be_false
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# Binary content — verifies binary blobs survive the pack round-trip
# ---------------------------------------------------------------------------

describe "Git::Client.clone — binary content", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_binary_content_repo
  end

  it "preserves exact binary file content after clone" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-binary")
    begin
      Git::Client.clone("file://#{FIXTURE_BINARY_REPO}", Git.safe_fs(clone_dir))
      buf = IO::Memory.new
      File.open(File.join(clone_dir, "assets", "data.bin"), "rb") { |io| IO.copy(io, buf) }
      buf.to_slice.should eq(Bytes.new(256, &.to_u8))
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# reset — handles force-pushed (non-fast-forward) remote history
# ---------------------------------------------------------------------------

RESET_BARE_REPO = spec_tmp("crystal-git-reset-bare") + ".git"

describe "Git::Client.reset (integration)", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_fixture_repo
    run_git(SPEC_TMP, "clone", "--bare", FIXTURE_BARE_REPO, RESET_BARE_REPO) unless Dir.exists?(RESET_BARE_REPO)
  end

  it "resets working tree after upstream force-push" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-reset")
    begin
      Git::Client.clone("file://#{RESET_BARE_REPO}", Git.safe_fs(clone_dir))
      content = force_push_bare(RESET_BARE_REPO)
      Git::Client.reset(Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "force.txt")).should be_true
      File.read(File.join(clone_dir, "force.txt")).should eq(content)
      File.exists?(File.join(clone_dir, "README.md")).should be_false
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "pull raises NonFastForwardError on the same diverged repo (regression guard)" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-reset-pull")
    begin
      Git::Client.clone("file://#{RESET_BARE_REPO}", Git.safe_fs(clone_dir))
      force_push_bare(RESET_BARE_REPO)
      expect_raises(Git::NonFastForwardError) do
        Git::Client.pull(Git.safe_fs(clone_dir))
      end
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "sync updates working tree after upstream force-push without raising" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-sync")
    begin
      Git::Client.clone("file://#{RESET_BARE_REPO}", Git.safe_fs(clone_dir))
      content = force_push_bare(RESET_BARE_REPO)
      Git::Client.sync(Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "force.txt")).should be_true
      File.read(File.join(clone_dir, "force.txt")).should eq(content)
      File.exists?(File.join(clone_dir, "README.md")).should be_false
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# Shallow clone — depth: N limits fetched history
# ---------------------------------------------------------------------------

SHALLOW_BARE_REPO = spec_tmp("crystal-git-shallow-bare") + ".git"

describe "Git::Client.clone — shallow clone", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_linear_history_repo
    run_git(SPEC_TMP, "clone", "--bare", FIXTURE_LINEAR_REPO, SHALLOW_BARE_REPO) unless Dir.exists?(SHALLOW_BARE_REPO)
  end

  it "shallow clone depth 1 writes .git/shallow and checks out HEAD tree" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-shallow1")
    begin
      Git::Client.clone("file://#{FIXTURE_LINEAR_REPO}", Git.safe_fs(clone_dir), depth: 1)

      File.exists?(File.join(clone_dir, ".git", "shallow")).should be_true
      File.exists?(File.join(clone_dir, "data", "file20.txt")).should be_true
      File.exists?(File.join(clone_dir, "CHANGELOG.md")).should be_true
      File.read(File.join(clone_dir, "CHANGELOG.md")).should contain("## v20")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "shallow clone depth 5 writes .git/shallow" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-shallow5")
    begin
      Git::Client.clone("file://#{FIXTURE_LINEAR_REPO}", Git.safe_fs(clone_dir), depth: 5)

      File.exists?(File.join(clone_dir, ".git", "shallow")).should be_true
      File.exists?(File.join(clone_dir, "data", "file20.txt")).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "pull after shallow clone succeeds without NonFastForwardError" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-shallow-pull")
    begin
      Git::Client.clone("file://#{SHALLOW_BARE_REPO}", Git.safe_fs(clone_dir), depth: 1)
      add_commit_to_bare(SHALLOW_BARE_REPO, "extra.txt", "extra content\n")
      Git::Client.pull(Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "extra.txt")).should be_true
      File.read(File.join(clone_dir, "extra.txt")).should eq("extra content\n")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "sync after shallow clone succeeds" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-shallow-sync")
    begin
      Git::Client.clone("file://#{SHALLOW_BARE_REPO}", Git.safe_fs(clone_dir), depth: 1)
      add_commit_to_bare(SHALLOW_BARE_REPO, "synced.txt", "synced\n")
      Git::Client.sync(Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "synced.txt")).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "non-shallow clone of linear repo still works (regression guard)" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-noshallow")
    begin
      Git::Client.clone("file://#{FIXTURE_LINEAR_REPO}", Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, ".git", "shallow")).should be_false
      Dir.glob(File.join(clone_dir, "data", "*.txt")).size.should eq(20)
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# Annotated tag clone — branch: "v1.0" targets a tag ref
# ---------------------------------------------------------------------------

FIXTURE_TAGGED_REPO = File.join(__DIR__, "../fixtures/tagged_repo.git")

private def ensure_tagged_repo : Nil
  return if Dir.exists?(FIXTURE_TAGGED_REPO)
  ensure_linear_history_repo
  src = spec_tmp("crystal-git-tagged-src")
  run_git(SPEC_TMP, "clone", FIXTURE_LINEAR_REPO, src)
  run_git(src, "config", "user.email", "test@example.com")
  run_git(src, "config", "user.name", "Test")
  run_git(src, "-c", "tag.gpgSign=false",
    "tag", "-a", "v1.0", "-m", "Release 1.0")
  Dir.mkdir_p(File.dirname(FIXTURE_TAGGED_REPO))
  run_git(src, "clone", "--bare", src, FIXTURE_TAGGED_REPO)
  FileUtils.rm_rf(src)
end

describe "Git::Client.clone — annotated tag", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_tagged_repo
  end

  it "clones a specific annotated tag by name (detached HEAD, correct tree)" do
    pending pending_msg unless git_available?
    clone_dir = spec_tmp("crystal-git-tag-clone")
    begin
      Git::Client.clone("file://#{FIXTURE_TAGGED_REPO}", Git.safe_fs(clone_dir), branch: "v1.0")
      File.exists?(File.join(clone_dir, "CHANGELOG.md")).should be_true
      head = File.read(File.join(clone_dir, ".git", "HEAD")).strip
      head.should_not start_with("ref:")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "clone branch: 'HEAD' still works on a tagged repo (regression guard)" do
    pending pending_msg unless git_available?
    clone_dir = spec_tmp("crystal-git-tag-head")
    begin
      Git::Client.clone("file://#{FIXTURE_TAGGED_REPO}", Git.safe_fs(clone_dir))
      File.exists?(File.join(clone_dir, "CHANGELOG.md")).should be_true
      head = File.read(File.join(clone_dir, ".git", "HEAD")).strip
      head.should start_with("ref:")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# HTTP transport — Smart HTTP v2 end-to-end
# ---------------------------------------------------------------------------

# Returns the full path to git-http-backend by asking git for its exec-path.
private def git_http_backend_path : String?
  proc = Process.new("git", ["--exec-path"],
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
  exec_path = proc.output.gets_to_end.strip
  proc.wait
  path = File.join(exec_path, "git-http-backend")
  (File.exists?(path) && File::Info.executable?(path)) ? path : nil
rescue
  nil
end

# Starts an HTTP server backed by git-http-backend (one CGI process per request).
# *repo_root* is the directory containing the bare repo(s) to serve.
# Yields the bound port; shuts down the server when the block returns.
private def with_git_http_server(repo_root : String, backend : String, &block : Int32 ->) : Nil
  server = HTTP::Server.new do |ctx|
    env = {
      "GIT_PROJECT_ROOT"    => repo_root,
      "GIT_HTTP_EXPORT_ALL" => "1",
      "PATH_INFO"           => ctx.request.path,
      "QUERY_STRING"        => ctx.request.query || "",
      "REQUEST_METHOD"      => ctx.request.method,
      "CONTENT_TYPE"        => ctx.request.headers["Content-Type"]? || "",
      "HTTP_GIT_PROTOCOL"   => ctx.request.headers["Git-Protocol"]? || "",
    }

    body_bytes = Bytes.empty
    if body_io = ctx.request.body
      mem = IO::Memory.new
      IO.copy(body_io, mem)
      body_bytes = mem.to_slice
    end
    env["CONTENT_LENGTH"] = body_bytes.size.to_s unless body_bytes.empty?

    cgi_proc = Process.new(backend,
      env: env,
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Close)
    cgi_proc.input.write(body_bytes)
    cgi_proc.input.close
    cgi_out = IO::Memory.new
    IO.copy(cgi_proc.output, cgi_out)
    cgi_proc.wait
    cgi_out.rewind

    # Parse CGI response headers (CRLF-terminated, blank line ends them)
    status_code = 200
    while line = cgi_out.gets(chomp: true)
      break if line.empty?
      if line.starts_with?("Status:")
        status_code = line.split(' ', 3)[1].to_i? || 200
      elsif colon = line.index(':')
        ctx.response.headers[line[0, colon].strip] = line[(colon + 1)..].strip
      end
    end
    ctx.response.status_code = status_code
    IO.copy(cgi_out, ctx.response)
  end

  address = server.bind_tcp("127.0.0.1", 0)
  spawn server.listen
  begin
    block.call(address.port)
  ensure
    server.close
  end
end

describe "Git::Client — HTTP transport (Smart HTTP v2)", tags: "integration" do
  before_all do
    next unless git_available?
    ensure_fixture_repo
  end

  it "clones a repo via HTTP and negotiates Smart HTTP v2" do
    pending "git not available" unless git_available?
    bp = git_http_backend_path
    pending "git-http-backend not found" unless bp

    clone_dir = spec_tmp("crystal-git-http-clone")
    begin
      with_git_http_server(File.dirname(FIXTURE_BARE_REPO), bp || raise "git-http-backend not found") do |port|
        Git::Client.clone(
          "http://127.0.0.1:#{port}/#{File.basename(FIXTURE_BARE_REPO)}",
          Git.safe_fs(clone_dir)
        )
      end
      File.read(File.join(clone_dir, "README.md")).should eq("hello from crystal-git\n")
      File.exists?(File.join(clone_dir, "src", "main.cr")).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "pulls a new commit via HTTP" do
    pending "git not available" unless git_available?
    bp = git_http_backend_path
    pending "git-http-backend not found" unless bp

    # Use a fresh per-test mutable copy of the fixture so parallel pulls don't race
    http_bare = spec_tmp("crystal-git-http-pull-bare") + ".git"
    clone_dir = spec_tmp("crystal-git-http-pull-clone")
    begin
      run_git(SPEC_TMP, "clone", "--bare", FIXTURE_BARE_REPO, http_bare)
      with_git_http_server(File.dirname(http_bare), bp || raise "git-http-backend not found") do |port|
        repo_url = "http://127.0.0.1:#{port}/#{File.basename(http_bare)}"
        Git::Client.clone(repo_url, Git.safe_fs(clone_dir))
        add_commit_to_bare(http_bare, "http_new.txt", "via http v2\n")
        Git::Client.pull(Git.safe_fs(clone_dir))
        File.read(File.join(clone_dir, "http_new.txt")).should eq("via http v2\n")
      end
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
      FileUtils.rm_rf(http_bare) if Dir.exists?(http_bare)
    end
  end

  it "sends Git-Protocol: version=2 header during clone (regression guard)" do
    pending "git not available" unless git_available?

    clone_dir = spec_tmp("crystal-git-http-v2hdr")
    captured = Channel(String?).new(1)
    server = HTTP::Server.new do |ctx|
      captured.send(ctx.request.headers["Git-Protocol"]?) unless captured.closed?
      ctx.response.status_code = 200
      ctx.response.headers["Content-Type"] = "application/x-git-upload-pack-advertisement"
      ctx.response.print("")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn server.listen
    begin
      Git::Client.clone("http://127.0.0.1:#{address.port}/repo.git", Git.safe_fs(clone_dir)) rescue Git::Error
      captured.receive?.should eq("version=2")
    ensure
      server.close
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# Separate git_dir — git_dir: parameter on Client.clone
# ---------------------------------------------------------------------------

SEPARATE_GIT_BARE_REPO = spec_tmp("crystal-git-separate-bare") + ".git"

describe "Git::Client.clone — separate git_dir", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_fixture_repo
    run_git(SPEC_TMP, "clone", "--bare", FIXTURE_BARE_REPO, SEPARATE_GIT_BARE_REPO) unless Dir.exists?(SEPARATE_GIT_BARE_REPO)
  end

  it "clones with git_dir: writes a gitfile and places objects in the separate dir" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-sep-wt")
    separate_dir = spec_tmp("crystal-git-sep-git")
    begin
      Git::Client.clone("file://#{SEPARATE_GIT_BARE_REPO}", Git.safe_fs(clone_dir), git_dir: Git.fs(separate_dir))

      File.file?(File.join(clone_dir, ".git")).should be_true
      File.read(File.join(clone_dir, ".git")).should start_with("gitdir: ")
      Dir.exists?(File.join(separate_dir, "objects", "pack")).should be_true
      File.exists?(File.join(clone_dir, "README.md")).should be_true
      File.read(File.join(clone_dir, "README.md")).should eq("hello from crystal-git\n")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
      FileUtils.rm_rf(separate_dir) if Dir.exists?(separate_dir)
    end
  end

  it "pull works on a repo cloned with a separate git_dir" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-sep-pull-wt")
    separate_dir = spec_tmp("crystal-git-sep-pull-git")
    begin
      Git::Client.clone("file://#{SEPARATE_GIT_BARE_REPO}", Git.safe_fs(clone_dir), git_dir: Git.fs(separate_dir))
      add_commit_to_bare(SEPARATE_GIT_BARE_REPO, "sep_newfile.txt", "separate git dir pull\n")
      Git::Client.pull(Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "sep_newfile.txt")).should be_true
      File.read(File.join(clone_dir, "sep_newfile.txt")).should eq("separate git dir pull\n")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
      FileUtils.rm_rf(separate_dir) if Dir.exists?(separate_dir)
    end
  end

  it "reset works on a repo cloned with a separate git_dir after force-push" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-sep-reset-wt")
    separate_dir = spec_tmp("crystal-git-sep-reset-git")
    begin
      Git::Client.clone("file://#{SEPARATE_GIT_BARE_REPO}", Git.safe_fs(clone_dir), git_dir: Git.fs(separate_dir))
      content = force_push_bare(SEPARATE_GIT_BARE_REPO)
      Git::Client.reset(Git.safe_fs(clone_dir))

      File.exists?(File.join(clone_dir, "force.txt")).should be_true
      File.read(File.join(clone_dir, "force.txt")).should eq(content)
      File.exists?(File.join(clone_dir, "README.md")).should be_false
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
      FileUtils.rm_rf(separate_dir) if Dir.exists?(separate_dir)
    end
  end
end

# ---------------------------------------------------------------------------
# Ref management — remote-tracking refs, FETCH_HEAD, ORIG_HEAD, reflogs
# ---------------------------------------------------------------------------

REF_MGMT_BARE_REPO = spec_tmp("crystal-git-refmgmt-bare") + ".git"

describe "Git::Client — ref management (integration)", tags: "integration" do
  pending_msg = "git not available" unless git_available?

  before_all do
    next unless git_available?
    ensure_fixture_repo
    run_git(SPEC_TMP, "clone", "--bare", FIXTURE_BARE_REPO, REF_MGMT_BARE_REPO) unless Dir.exists?(REF_MGMT_BARE_REPO)
  end

  it "clone writes refs/remotes/origin/<branch> loose file" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-refmgmt-clone")
    begin
      Git::Client.clone("file://#{REF_MGMT_BARE_REPO}", Git.safe_fs(clone_dir))
      tracking = File.join(clone_dir, ".git", "refs", "remotes", "origin", "main")
      File.exists?(tracking).should be_true
      oid_hex = File.read(tracking).strip
      oid_hex.size.should eq(40)
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "clone writes FETCH_HEAD containing the branch oid and url" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-refmgmt-fh")
    begin
      url = "file://#{REF_MGMT_BARE_REPO}"
      Git::Client.clone(url, Git.safe_fs(clone_dir))
      fetch_head = File.read(File.join(clone_dir, ".git", "FETCH_HEAD"))
      fetch_head.should contain("main")
      fetch_head.should contain(REF_MGMT_BARE_REPO)
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "clone writes .git/logs/HEAD reflog" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-refmgmt-log")
    begin
      Git::Client.clone("file://#{REF_MGMT_BARE_REPO}", Git.safe_fs(clone_dir))
      log_head = File.join(clone_dir, ".git", "logs", "HEAD")
      File.exists?(log_head).should be_true
      content = File.read(log_head)
      content.should contain("clone:")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "clone writes .git/logs/refs/heads/<branch> reflog" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-refmgmt-logbr")
    begin
      Git::Client.clone("file://#{REF_MGMT_BARE_REPO}", Git.safe_fs(clone_dir))
      log_branch = File.join(clone_dir, ".git", "logs", "refs", "heads", "main")
      File.exists?(log_branch).should be_true
      File.read(log_branch).should contain("clone:")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "pull updates remote-tracking ref and writes FETCH_HEAD" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-refmgmt-pull")
    bare = spec_tmp("crystal-git-refmgmt-pull-bare") + ".git"
    begin
      run_git(SPEC_TMP, "clone", "--bare", REF_MGMT_BARE_REPO, bare)
      Git::Client.clone("file://#{bare}", Git.safe_fs(clone_dir))
      tip_before = File.read(File.join(clone_dir, ".git", "refs", "remotes", "origin", "main")).strip

      add_commit_to_bare(bare, "ref_mgmt_test.txt", "hello\n")
      Git::Client.pull(Git.safe_fs(clone_dir))

      tip_after = File.read(File.join(clone_dir, ".git", "refs", "remotes", "origin", "main")).strip
      tip_after.should_not eq(tip_before)
      File.exists?(File.join(clone_dir, ".git", "FETCH_HEAD")).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
      FileUtils.rm_rf(bare) if Dir.exists?(bare)
    end
  end

  it "reset writes ORIG_HEAD with the pre-reset tip" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-refmgmt-reset")
    bare = spec_tmp("crystal-git-refmgmt-reset-bare") + ".git"
    begin
      run_git(SPEC_TMP, "clone", "--bare", REF_MGMT_BARE_REPO, bare)
      Git::Client.clone("file://#{bare}", Git.safe_fs(clone_dir))

      repo = Git::Repository.open(Git::FileSystem::Local.new(clone_dir))
      old_tip = repo.branch_tip("main")

      force_push_bare(bare)
      Git::Client.reset(Git.safe_fs(clone_dir))

      orig_head = repo.read_orig_head
      orig_head.should_not be_nil
      orig_head.should eq(old_tip)
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
      FileUtils.rm_rf(bare) if Dir.exists?(bare)
    end
  end

  it "pull appends reflog entries after fetch" do
    pending pending_msg unless git_available?

    clone_dir = spec_tmp("crystal-git-refmgmt-pulllog")
    bare = spec_tmp("crystal-git-refmgmt-pulllog-bare") + ".git"
    begin
      run_git(SPEC_TMP, "clone", "--bare", REF_MGMT_BARE_REPO, bare)
      Git::Client.clone("file://#{bare}", Git.safe_fs(clone_dir))

      clone_log_lines = File.read_lines(File.join(clone_dir, ".git", "logs", "HEAD")).reject(&.empty?)

      add_commit_to_bare(bare, "pulllog_test.txt", "data\n")
      Git::Client.pull(Git.safe_fs(clone_dir))

      pull_log_lines = File.read_lines(File.join(clone_dir, ".git", "logs", "HEAD")).reject(&.empty?)
      pull_log_lines.size.should be > clone_log_lines.size
      pull_log_lines.last.should contain("pull:")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
      FileUtils.rm_rf(bare) if Dir.exists?(bare)
    end
  end
end
