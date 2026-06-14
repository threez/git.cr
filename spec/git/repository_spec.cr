require "../spec_helper"
require "file_utils"

describe Git::Repository do
  tmp = uninitialized String
  mem_fs = uninitialized Git::FileSystem::Memory

  around_each do |example|
    tmp = spec_tmp("repo-spec")
    Dir.mkdir_p(tmp)
    mem_fs = Git::FileSystem::Memory.new("/repo-#{Random::Secure.hex(6)}")
    example.run
    FileUtils.rm_rf(tmp)
  end

  describe ".init" do
    it "creates .git/objects/pack, refs/heads, refs/tags" do
      repo = Git::Repository.init(mem_fs)
      repo.git_dir.directory?(repo.git_dir.join("objects", "pack")).should be_true
      repo.git_dir.directory?(repo.git_dir.join("refs", "heads")).should be_true
      repo.git_dir.directory?(repo.git_dir.join("refs", "tags")).should be_true
    end

    it "raises RepositoryError if .git/ already exists" do
      Git::Repository.init(mem_fs)
      expect_raises(Git::RepositoryError) { Git::Repository.init(mem_fs) }
    end

    it "creates git directory at a separate path and writes a gitfile" do
      separate_fs = mem_fs.chroot("git-store")
      repo = Git::Repository.init(mem_fs, separate_fs)
      repo.git_dir.root.should eq(separate_fs.root)
      separate_fs.directory?(separate_fs.join("objects", "pack")).should be_true
      separate_fs.directory?(separate_fs.join("refs", "heads")).should be_true
      mem_fs.file?(mem_fs.join(".git")).should be_true
      mem_fs.read(mem_fs.join(".git")).should eq("gitdir: #{separate_fs.root}\n")
    end

    it "gitfile stores an absolute path even when a relative git_dir is given" do
      # Relative paths are expanded against Dir.current (like git's --separate-git-dir CLI flag).
      # We use a randomly named subdir of tmp to avoid collisions with other runs.
      rand_name = "git-store-#{Random::Secure.hex(4)}"
      rel = File.join(Dir.current, rand_name)
      begin
        Git::Repository.init(Git::FileSystem::Local.new(tmp), Git::FileSystem::Local.new(rand_name))
        content = File.read(File.join(tmp, ".git"))
        raw_path = content.lchop("gitdir: ").chomp
        raw_path.starts_with?("/").should be_true
        raw_path.should eq(rel)
        Dir.exists?(File.join(rel, "objects", "pack")).should be_true
      ensure
        FileUtils.rm_rf(rel) if Dir.exists?(rel)
      end
    end

    it "accepts an empty pre-existing separate git_dir without error" do
      separate_fs = mem_fs.chroot("git-store")
      separate_fs.mkdir_p(separate_fs.root)
      repo = Git::Repository.init(mem_fs, separate_fs)
      repo.git_dir.root.should eq(separate_fs.root)
    end

    it "raises RepositoryError when the separate git_dir is non-empty" do
      separate_fs = mem_fs.chroot("git-store")
      separate_fs.write(separate_fs.join("existing"), "data")
      expect_raises(Git::RepositoryError) { Git::Repository.init(mem_fs, separate_fs) }
    end

    it "raises RepositoryError when .git already exists and a separate git_dir is given" do
      Git::Repository.init(mem_fs)
      separate2_fs = mem_fs.chroot("git-store2")
      expect_raises(Git::RepositoryError) { Git::Repository.init(mem_fs, separate2_fs) }
    end
  end

  describe ".open" do
    it "returns a Repository when .git/ exists" do
      Git::Repository.init(mem_fs)
      repo = Git::Repository.open(mem_fs)
      repo.git_dir.root.should eq(File.join(mem_fs.root, ".git"))
    end

    it "raises RepositoryError when .git/ is absent" do
      expect_raises(Git::RepositoryError) { Git::Repository.open(mem_fs) }
    end

    it "reads git_dir from a gitfile when .git is a plain file" do
      separate = File.join(tmp, "git-store")
      Dir.mkdir_p(File.join(separate, "objects", "pack"))
      File.write(File.join(tmp, ".git"), "gitdir: #{separate}\n")
      repo = Git::Repository.open(Git::FileSystem::Local.new(tmp))
      repo.git_dir.root.should eq(separate)
    end

    it "resolves a relative path in the gitfile against work_dir" do
      separate = File.join(tmp, "git-store")
      Dir.mkdir_p(File.join(separate, "objects", "pack"))
      File.write(File.join(tmp, ".git"), "gitdir: git-store\n")
      repo = Git::Repository.open(Git::FileSystem::Local.new(tmp))
      repo.git_dir.root.should eq(separate)
    end

    it "raises RepositoryError for a malformed gitfile missing gitdir: prefix" do
      mem_fs.write(mem_fs.join(".git"), "garbage\n")
      expect_raises(Git::RepositoryError) { Git::Repository.open(mem_fs) }
    end

    it "raises RepositoryError when the path in the gitfile does not exist" do
      mem_fs.write(mem_fs.join(".git"), "gitdir: /nonexistent/path/that/does/not/exist\n")
      expect_raises(Git::RepositoryError) { Git::Repository.open(mem_fs) }
    end
  end

  describe "separate git_dir round-trip" do
    it "init with separate git_dir → open → write_head → current_branch" do
      separate = File.join(tmp, "git-store")
      Git::Repository.init(Git::FileSystem::Local.new(tmp), Git::FileSystem::Local.new(separate))
      repo = Git::Repository.open(Git::FileSystem::Local.new(tmp))
      repo.git_dir.root.should eq(separate)
      repo.write_head("main")
      repo.current_branch.should eq("main")
    end
  end

  describe "#write_head / #current_branch" do
    it "round-trips a branch name through HEAD" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      repo.write_head("main")
      repo.current_branch.should eq("main")
    end

    it "raises RepositoryError when HEAD is not a symref" do
      repo = Git::Repository.init(mem_fs)
      repo.git_dir.write(repo.git_dir.join("HEAD"), "abc123\n")
      expect_raises(Git::RepositoryError) { repo.current_branch }
    end

    it "raises LockError when HEAD.lock already exists" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      File.write(File.join(repo.git_dir.root, "HEAD.lock"), "stale")
      expect_raises(Git::LockError) { repo.write_head("main") }
    end
  end

  describe "#read_head_oid" do
    it "returns the OID when HEAD is a raw SHA-1 (detached HEAD)" do
      # Regression: previously Submodule.init_all called current_branch which raises
      # on detached HEAD. The fix switched to read_head_oid, which must handle raw SHA-1.
      repo = Git::Repository.init(mem_fs)
      expected = Git.oid("c" * 40)
      repo.git_dir.write(repo.git_dir.join("HEAD"), "#{expected.to_hex}\n")
      repo.read_head_oid.should eq(expected)
    end
  end

  describe "#write_detached_head" do
    it "raises LockError when HEAD.lock already exists" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("d" * 40)
      File.write(File.join(repo.git_dir.root, "HEAD.lock"), "stale")
      expect_raises(Git::LockError) { repo.write_detached_head(oid) }
    end
  end

  describe "#write_branch / #branch_tip" do
    it "round-trips an OID through a loose ref" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("a" * 40)
      repo.write_branch("main", oid)
      repo.branch_tip("main").should eq(oid)
    end

    it "reads branch tip from packed-refs when loose ref is absent" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("b" * 40)
      fake_ref = Git::Repository::Ref.new("refs/heads/main", oid)
      repo.write_packed_refs([fake_ref])
      repo.branch_tip("main").should eq(oid)
    end

    it "raises RepositoryError for an unknown branch" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      expect_raises(Git::RepositoryError) { repo.branch_tip("nonexistent") }
    end

    it "raises LockError when the branch ref.lock already exists" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("a" * 40)
      lock = File.join(repo.git_dir.root, "refs", "heads", "main.lock")
      Dir.mkdir_p(File.dirname(lock))
      File.write(lock, "stale")
      expect_raises(Git::LockError) { repo.write_branch("main", oid) }
    end
  end

  describe "#write_packed_refs" do
    it "writes refs sorted by name" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("0" * 40)
      refs = [
        Git::Repository::Ref.new("refs/heads/zzz", oid),
        Git::Repository::Ref.new("refs/heads/aaa", oid),
      ]
      repo.write_packed_refs(refs)
      lines = File.read(File.join(repo.git_dir.root, "packed-refs")).lines.reject(&.starts_with?('#'))
      lines[0].should contain("refs/heads/aaa")
      lines[1].should contain("refs/heads/zzz")
    end

    it "raises LockError when packed-refs.lock already exists" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      File.write(File.join(repo.git_dir.root, "packed-refs.lock"), "stale")
      expect_raises(Git::LockError) { repo.write_packed_refs([] of Git::Repository::Ref) }
    end
  end

  describe "#write_config" do
    it "raises LockError when config.lock already exists" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      File.write(File.join(repo.git_dir.root, "config.lock"), "stale")
      expect_raises(Git::LockError) { repo.write_config("https://example.com/repo.git") }
    end
  end

  describe "#write_shallow" do
    it "raises LockError when shallow.lock already exists" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("c" * 40)
      File.write(File.join(repo.git_dir.root, "shallow.lock"), "stale")
      expect_raises(Git::LockError) { repo.write_shallow([oid]) }
    end
  end

  describe ".init creates refs/remotes" do
    it "creates refs/remotes directory" do
      repo = Git::Repository.init(mem_fs)
      repo.git_dir.directory?(repo.git_dir.join("refs", "remotes")).should be_true
    end

    it "creates refs/remotes with separate git_dir" do
      separate_fs = mem_fs.chroot("git-store")
      Git::Repository.init(mem_fs, separate_fs)
      separate_fs.directory?(separate_fs.join("refs", "remotes")).should be_true
    end
  end

  describe "#write_tracking_ref / #tracking_ref_tip" do
    it "round-trips an OID through a loose tracking ref" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("a" * 40)
      repo.write_tracking_ref("origin", "main", oid)
      repo.tracking_ref_tip("origin", "main").should eq(oid)
    end

    it "returns nil for an absent tracking ref" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      repo.tracking_ref_tip("origin", "nonexistent").should be_nil
    end

    it "creates nested remote directories as needed" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("b" * 40)
      repo.write_tracking_ref("upstream", "feature/x", oid)
      repo.tracking_ref_tip("upstream", "feature/x").should eq(oid)
    end
  end

  describe "#write_tracking_refs" do
    it "writes a loose file for each refs/heads/* ref" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid1 = Git.oid("1" * 40)
      oid2 = Git.oid("2" * 40)
      refs = [
        Git::Repository::Ref.new("refs/heads/main", oid1),
        Git::Repository::Ref.new("refs/heads/dev", oid2),
        Git::Repository::Ref.new("refs/tags/v1.0", oid1),
      ]
      repo.write_tracking_refs("origin", refs)
      repo.tracking_ref_tip("origin", "main").should eq(oid1)
      repo.tracking_ref_tip("origin", "dev").should eq(oid2)
      repo.tracking_ref_tip("origin", "v1.0").should be_nil
    end
  end

  describe "#write_fetch_head" do
    it "writes FETCH_HEAD with oid, branch name, and url" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("f" * 40)
      repo.write_fetch_head(oid, "main", "https://example.com/repo.git")
      content = File.read(File.join(repo.git_dir.root, "FETCH_HEAD"))
      content.should contain(oid.to_hex)
      content.should contain("main")
      content.should contain("https://example.com/repo.git")
    end

    it "raises LockError when FETCH_HEAD.lock already exists" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("f" * 40)
      File.write(File.join(repo.git_dir.root, "FETCH_HEAD.lock"), "stale")
      expect_raises(Git::LockError) { repo.write_fetch_head(oid, "main", "https://example.com") }
    end
  end

  describe "#write_orig_head / #read_orig_head" do
    it "round-trips an OID through ORIG_HEAD" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("0" * 40)
      repo.write_orig_head(oid)
      repo.read_orig_head.should eq(oid)
    end

    it "returns nil when ORIG_HEAD does not exist" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      repo.read_orig_head.should be_nil
    end

    it "overwrites an existing ORIG_HEAD" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid1 = Git.oid("1" * 40)
      oid2 = Git.oid("2" * 40)
      repo.write_orig_head(oid1)
      repo.write_orig_head(oid2)
      repo.read_orig_head.should eq(oid2)
    end
  end

  describe "#delete_ref" do
    it "deletes a loose ref" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("d" * 40)
      repo.write_branch("gone", oid)
      repo.branch_tip("gone").should eq(oid)
      repo.delete_ref("refs/heads/gone")
      expect_raises(Git::RepositoryError) { repo.branch_tip("gone") }
    end

    it "removes a ref from packed-refs" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid = Git.oid("e" * 40)
      refs = [
        Git::Repository::Ref.new("refs/heads/keep", oid),
        Git::Repository::Ref.new("refs/heads/gone", oid),
      ]
      repo.write_packed_refs(refs)
      repo.delete_ref("refs/heads/gone")
      content = File.read(File.join(repo.git_dir.root, "packed-refs"))
      content.should contain("refs/heads/keep")
      content.should_not contain("refs/heads/gone")
    end

    it "is a no-op when the ref does not exist" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      repo.delete_ref("refs/heads/nonexistent")
    end

    it "deletes both loose and packed-refs entry when both exist" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid1 = Git.oid("1" * 40)
      oid2 = Git.oid("2" * 40)
      repo.write_branch("gone", oid1)
      repo.write_packed_refs([Git::Repository::Ref.new("refs/heads/gone", oid2)])
      repo.delete_ref("refs/heads/gone")
      expect_raises(Git::RepositoryError) { repo.branch_tip("gone") }
      content = File.read(File.join(repo.git_dir.root, "packed-refs"))
      content.should_not contain("refs/heads/gone")
    end
  end

  describe "#append_reflog" do
    it "creates the log file and writes one entry" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      old_oid = Git.oid("0" * 40)
      new_oid = Git.oid("a" * 40)
      repo.append_reflog("refs/heads/main", old_oid, new_oid, "clone: from https://example.com")
      log_path = File.join(repo.git_dir.root, "logs", "refs", "heads", "main")
      File.exists?(log_path).should be_true
      content = File.read(log_path)
      content.should contain(old_oid.to_hex)
      content.should contain(new_oid.to_hex)
      content.should contain("clone: from https://example.com")
    end

    it "appends multiple entries to the same log file" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      oid1 = Git.oid("1" * 40)
      oid2 = Git.oid("2" * 40)
      oid3 = Git.oid("3" * 40)
      repo.append_reflog("HEAD", oid1, oid2, "first")
      repo.append_reflog("HEAD", oid2, oid3, "second")
      log_path = File.join(repo.git_dir.root, "logs", "HEAD")
      lines = File.read_lines(log_path).reject(&.empty?)
      lines.size.should eq(2)
      lines[0].should contain("first")
      lines[1].should contain("second")
    end

    it "creates parent directories as needed" do
      repo = Git::Repository.init(Git::FileSystem::Local.new(tmp))
      old_oid = Git.oid("0" * 40)
      new_oid = Git.oid("b" * 40)
      repo.append_reflog("refs/remotes/origin/main", old_oid, new_oid, "fetch")
      log_path = File.join(repo.git_dir.root, "logs", "refs", "remotes", "origin", "main")
      File.exists?(log_path).should be_true
    end
  end
end
