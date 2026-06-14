require "../../spec_helper"
require "file_utils"

# Builds an in-memory pack containing a commit → tree → blob chain.
# Returns {resolver, commit_oid, blob_oid, blob_data}.
# Craft a commit → (one-entry tree with attacker-controlled name) → blob pack.
# Used by path traversal regression tests.
private def build_malicious_pack(dir : String, tree_entry_name : String) : {Git::Pack::Resolver, Git::Object::Id}
  blob_data = "payload\n".to_slice
  blob_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, blob_data)

  tree_io = IO::Memory.new
  tree_io.write("100644 #{tree_entry_name}\0".to_slice)
  tree_io.write(blob_oid.to_bytes)
  tree_data = tree_io.to_slice
  tree_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Tree, tree_data)

  commit_body = "tree #{tree_oid.to_hex}\nauthor T <t@t.com> 0 +0000\ncommitter T <t@t.com> 0 +0000\n\nEvil\n"
  commit_data = commit_body.to_slice
  commit_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Commit, commit_data)

  pack_path = File.join(dir, "#{Random::Secure.hex(4)}.pack")
  write_spec_pack(pack_path, [
    {blob_oid, Git::Pack::ObjectType::Blob, blob_data},
    {tree_oid, Git::Pack::ObjectType::Tree, tree_data},
    {commit_oid, Git::Pack::ObjectType::Commit, commit_data},
  ])
  resolver = Git::Pack::Resolver.new(pack_path, 3)
  resolver.resolve!
  {resolver, commit_oid}
end

private def build_simple_pack(dir : String) : {Git::Pack::Resolver, Git::Object::Id, Git::Object::Id, Bytes}
  blob_data = "hello checkout\n".to_slice
  blob_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, blob_data)

  # Tree: one blob entry named "hello.txt" with mode 100644
  tree_io = IO::Memory.new
  tree_io.write("100644 hello.txt\0".to_slice)
  tree_io.write(blob_oid.to_bytes)
  tree_data = tree_io.to_slice
  tree_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Tree, tree_data)

  commit_body = "tree #{tree_oid.to_hex}\nauthor Test <t@t.com> 0 +0000\ncommitter Test <t@t.com> 0 +0000\n\nInit\n"
  commit_data = commit_body.to_slice
  commit_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Commit, commit_data)

  pack_path = File.join(dir, "test.pack")
  write_spec_pack(pack_path, [
    {blob_oid, Git::Pack::ObjectType::Blob, blob_data},
    {tree_oid, Git::Pack::ObjectType::Tree, tree_data},
    {commit_oid, Git::Pack::ObjectType::Commit, commit_data},
  ])

  resolver = Git::Pack::Resolver.new(pack_path, 3)
  resolver.resolve!
  {resolver, commit_oid, blob_oid, blob_data}
end

describe Git::Worktree::Checkout do
  work_fs = uninitialized Git::FileSystem::Memory
  pack_dir = uninitialized String

  around_each do |example|
    work_fs = Git::FileSystem::Memory.new("/work-#{Random::Secure.hex(6)}")
    pack_dir = spec_tmp("checkout-pack")
    Dir.mkdir_p(pack_dir)
    example.run
    FileUtils.rm_rf(pack_dir)
  end

  describe ".run" do
    it "writes tree files to the working directory" do
      resolver, commit_oid, _, blob_data = build_simple_pack(pack_dir)
      Git::Worktree::Checkout.run(resolver, commit_oid, work_fs, file_system: work_fs)
      work_fs.read("hello.txt").should eq(String.new(blob_data))
    end

    it "raises if HEAD commit is not found" do
      write_spec_pack(File.join(pack_dir, "empty.pack"), [] of {Git::Object::Id, Git::Pack::ObjectType, Bytes})
      resolver = Git::Pack::Resolver.new(File.join(pack_dir, "empty.pack"), 0)
      resolver.resolve!
      fake_oid = Git.oid("a" * 40)
      expect_raises(Git::Error) { Git::Worktree::Checkout.run(resolver, fake_oid, work_fs, file_system: work_fs) }
    end
  end

  describe "path traversal protection" do
    it "raises when a tree entry name is '..'" do
      resolver, commit_oid = build_malicious_pack(pack_dir, "..")
      expect_raises(Git::ProtocolError) { Git::Worktree::Checkout.run(resolver, commit_oid, work_fs, file_system: work_fs) }
    end

    it "raises when a tree entry name is '.GIT' (case-insensitive .git check)" do
      resolver, commit_oid = build_malicious_pack(pack_dir, ".GIT")
      expect_raises(Git::ProtocolError) { Git::Worktree::Checkout.run(resolver, commit_oid, work_fs, file_system: work_fs) }
    end

    it "raises when a tree entry name contains '/'" do
      resolver, commit_oid = build_malicious_pack(pack_dir, "foo/bar")
      expect_raises(Git::ProtocolError) { Git::Worktree::Checkout.run(resolver, commit_oid, work_fs, file_system: work_fs) }
    end

    it "raises when apply_changes would write through a symlink parent directory" do
      # This test requires a real on-disk directory to plant a genuine filesystem symlink.
      real_work = spec_tmp("checkout-sym")
      Dir.mkdir_p(real_work)
      begin
        blob_data = "secret\n".to_slice
        blob_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, blob_data)
        store = make_spec_store([{blob_oid, Git::Pack::ObjectType::Blob, blob_data}])

        sym_path = File.join(real_work, "subdir")
        File.symlink("/tmp", sym_path)

        changes = [Git::Worktree::Change.new(
          Git::Worktree::Change::Kind::Added, "subdir/evil.txt", blob_oid, 0o100644_u32
        )]
        expect_raises(Git::Error) { Git::Worktree::Checkout.apply_changes(Git::FileSystem::Guarded.new(real_work), store, changes) }

        File.delete(sym_path) if File.symlink?(sym_path)
      ensure
        FileUtils.rm_rf(real_work)
      end
    end
  end

  describe ".apply_changes" do
    it "creates an Added file" do
      blob_data2 = "added content\n".to_slice
      blob_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, blob_data2)
      store = make_spec_store([
        {blob_oid, Git::Pack::ObjectType::Blob, blob_data2},
      ])
      changes = [Git::Worktree::Change.new(Git::Worktree::Change::Kind::Added, "new.txt", blob_oid, 0o100644_u32)]
      Git::Worktree::Checkout.apply_changes(work_fs, store, changes, file_system: work_fs)
      work_fs.read("new.txt").should eq("added content\n")
    end

    it "deletes a Deleted file" do
      work_fs.write("gone.txt", "bye\n")
      store = make_spec_store([] of {Git::Object::Id, Git::Pack::ObjectType, Bytes})
      changes = [Git::Worktree::Change.new(Git::Worktree::Change::Kind::Deleted, "gone.txt")]
      Git::Worktree::Checkout.apply_changes(work_fs, store, changes, file_system: work_fs)
      work_fs.exists?("gone.txt").should be_false
    end
  end
end
