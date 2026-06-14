require "../../spec_helper"
require "file_utils"

FIXTURE_SUB_REPO        = File.join(__DIR__, "../../fixtures/sub.git")
FIXTURE_PARENT_REPO     = File.join(__DIR__, "../../fixtures/submodule_parent.git")
FIXTURE_PINNED_SUB_REPO = File.join(__DIR__, "../../fixtures/pinned_sub.git")
FIXTURE_PINNED_PARENT   = File.join(__DIR__, "../../fixtures/pinned_parent.git")

private def git_available_sub? : Bool
  Process.find_executable("git") != nil
end

private def run_git_sub(dir : String, *args : String) : Nil
  proc = Process.new("git", args: args.to_a, chdir: dir,
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  raise "git #{args.join(" ")} failed in #{dir}" unless proc.wait.success?
end

private def ensure_sub_fixture : Nil
  return if Dir.exists?(FIXTURE_SUB_REPO)
  src = spec_tmp("crystal-git-sub")
  Dir.mkdir_p(src)
  run_git_sub(src, "init", "-b", "main")
  run_git_sub(src, "config", "user.email", "test@example.com")
  run_git_sub(src, "config", "user.name", "Test")
  File.write(File.join(src, "hello.txt"), "hello from submodule\n")
  run_git_sub(src, "add", ".")
  run_git_sub(src, "commit", "-m", "Initial submodule commit")
  Dir.mkdir_p(File.dirname(FIXTURE_SUB_REPO))
  run_git_sub(src, "clone", "--bare", src, FIXTURE_SUB_REPO)
  FileUtils.rm_rf(src)
end

private def ensure_parent_fixture : Nil
  return if Dir.exists?(FIXTURE_PARENT_REPO)
  ensure_sub_fixture
  src = spec_tmp("crystal-git-parent")
  Dir.mkdir_p(src)
  run_git_sub(src, "init", "-b", "main")
  run_git_sub(src, "config", "user.email", "test@example.com")
  run_git_sub(src, "config", "user.name", "Test")
  File.write(File.join(src, "README.md"), "parent repo\n")
  run_git_sub(src, "add", ".")
  run_git_sub(src, "commit", "-m", "Initial commit")
  run_git_sub(src, "-c", "protocol.file.allow=always",
    "submodule", "add", "--", "file://#{FIXTURE_SUB_REPO}", "vendor/sub")
  run_git_sub(src, "commit", "-m", "Add submodule")
  Dir.mkdir_p(File.dirname(FIXTURE_PARENT_REPO))
  run_git_sub(src, "clone", "--bare", src, FIXTURE_PARENT_REPO)
  FileUtils.rm_rf(src)
end

private def ensure_pinned_fixtures : Nil
  return if Dir.exists?(FIXTURE_PINNED_PARENT)

  # Build a submodule bare repo with two commits:
  #   Commit A — only hello.txt
  #   Commit B — also adds v2.txt (this becomes HEAD)
  sub_src = spec_tmp("crystal-git-pinned-sub")
  Dir.mkdir_p(sub_src)
  run_git_sub(sub_src, "init", "-b", "main")
  run_git_sub(sub_src, "config", "user.email", "test@example.com")
  run_git_sub(sub_src, "config", "user.name", "Test")
  File.write(File.join(sub_src, "hello.txt"), "hello from submodule\n")
  run_git_sub(sub_src, "add", ".")
  run_git_sub(sub_src, "commit", "-m", "Commit A")
  # Capture commit A OID before adding commit B
  commit_a_proc = Process.new("git", args: ["rev-parse", "HEAD"],
    chdir: sub_src, output: Process::Redirect::Pipe, error: Process::Redirect::Close)
  commit_a_output = commit_a_proc.output.read_line.strip
  commit_a_proc.wait
  File.write(File.join(sub_src, "v2.txt"), "version 2\n")
  run_git_sub(sub_src, "add", ".")
  run_git_sub(sub_src, "commit", "-m", "Commit B")
  Dir.mkdir_p(File.dirname(FIXTURE_PINNED_SUB_REPO))
  run_git_sub(sub_src, "clone", "--bare", sub_src, FIXTURE_PINNED_SUB_REPO)
  FileUtils.rm_rf(sub_src)

  # Build a parent repo that pins the submodule at commit A (not HEAD=B).
  # Strategy: add submodule (gets HEAD=B), then manually reset the gitlink to A.
  parent_src = spec_tmp("crystal-git-pinned-parent")
  Dir.mkdir_p(parent_src)
  run_git_sub(parent_src, "init", "-b", "main")
  run_git_sub(parent_src, "config", "user.email", "test@example.com")
  run_git_sub(parent_src, "config", "user.name", "Test")
  File.write(File.join(parent_src, "README.md"), "pinned parent\n")
  run_git_sub(parent_src, "add", ".")
  run_git_sub(parent_src, "commit", "-m", "Initial commit")
  run_git_sub(parent_src, "-c", "protocol.file.allow=always",
    "submodule", "add", "--", "file://#{FIXTURE_PINNED_SUB_REPO}", "vendor/sub")
  # Checkout submodule at commit A so the gitlink records A
  sub_work = File.join(parent_src, "vendor", "sub")
  run_git_sub(sub_work, "checkout", commit_a_output)
  run_git_sub(parent_src, "add", "vendor/sub")
  run_git_sub(parent_src, "commit", "-m", "Pin submodule at commit A")
  Dir.mkdir_p(File.dirname(FIXTURE_PINNED_PARENT))
  run_git_sub(parent_src, "clone", "--bare", parent_src, FIXTURE_PINNED_PARENT)
  FileUtils.rm_rf(parent_src)
end

describe "Git::Client submodule support (integration)", tags: "integration" do
  pending_msg = "git not available" unless git_available_sub?

  before_all do
    next unless git_available_sub?
    ensure_parent_fixture
  end

  it "clones a repo with submodules (submodules: true by default)" do
    pending pending_msg unless git_available_sub?
    clone_dir = spec_tmp("crystal-git-sub-clone")
    begin
      Git::Client.clone("file://#{FIXTURE_PARENT_REPO}", Git.safe_fs(clone_dir))
      File.exists?(File.join(clone_dir, "README.md")).should be_true
      File.exists?(File.join(clone_dir, "vendor", "sub", "hello.txt")).should be_true
      File.read(File.join(clone_dir, "vendor", "sub", "hello.txt")).should eq("hello from submodule\n")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end

  it "clones without crashing when submodules: false (placeholder dirs created)" do
    pending pending_msg unless git_available_sub?
    clone_dir = spec_tmp("crystal-git-nosub-clone")
    begin
      Git::Client.clone("file://#{FIXTURE_PARENT_REPO}", Git.safe_fs(clone_dir), submodules: false)
      File.exists?(File.join(clone_dir, "README.md")).should be_true
      Dir.exists?(File.join(clone_dir, "vendor", "sub")).should be_true
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

describe "Git::Client submodule exact-commit pinning (integration)", tags: "integration" do
  pending_msg = "git not available" unless git_available_sub?

  before_all do
    next unless git_available_sub?
    ensure_pinned_fixtures
  end

  it "clones with submodule pinned at non-HEAD commit (v2.txt absent, hello.txt present)" do
    pending pending_msg unless git_available_sub?
    clone_dir = spec_tmp("crystal-git-pinned-clone")
    begin
      Git::Client.clone("file://#{FIXTURE_PINNED_PARENT}", Git.safe_fs(clone_dir))
      File.exists?(File.join(clone_dir, "vendor", "sub", "hello.txt")).should be_true
      File.exists?(File.join(clone_dir, "vendor", "sub", "v2.txt")).should be_false
      # Submodule HEAD should be detached (not a symbolic ref)
      head = File.read(File.join(clone_dir, "vendor", "sub", ".git", "HEAD")).strip
      head.should_not start_with("ref:")
    ensure
      FileUtils.rm_rf(clone_dir) if Dir.exists?(clone_dir)
    end
  end
end

describe "Git::Repository::Submodule" do
  describe ".read_gitmodules" do
    it "parses a .gitmodules file with one entry" do
      dir = spec_tmp("gitmodules-spec")
      Dir.mkdir_p(dir)
      begin
        File.write(File.join(dir, ".gitmodules"), <<-INI)
          [submodule "vendor/foo"]
          \tpath = vendor/foo
          \turl = https://example.com/foo.git
          INI
        entries = Git::Repository::Submodule.read_gitmodules(dir)
        entries.size.should eq(1)
        entries[0].name.should eq("vendor/foo")
        entries[0].path.should eq("vendor/foo")
        entries[0].url.should eq("https://example.com/foo.git")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "returns empty array when .gitmodules is absent" do
      dir = spec_tmp("no-gitmodules")
      Dir.mkdir_p(dir)
      begin
        Git::Repository::Submodule.read_gitmodules(dir).should be_empty
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe ".resolve_url" do
    it "returns absolute URLs unchanged" do
      parent = Git.remote("https://github.com/org/repo.git")
      Git::Repository::Submodule.resolve_url("https://example.com/other.git", parent).should eq("https://example.com/other.git")
    end

    it "resolves a ../ relative URL against the parent remote" do
      parent = Git.remote("https://github.com/org/repo.git")
      result = Git::Repository::Submodule.resolve_url("../other.git", parent)
      result.should eq("/org/other.git")
    end
  end
end
