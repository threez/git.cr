require "../../spec_helper"

private def make_blob(content : String) : {Git::Object::Id, Bytes}
  data = content.to_slice
  {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data), data}
end

private def make_tree(entries : Array({UInt32, String, Git::Object::Id})) : {Git::Object::Id, Bytes}
  buf = IO::Memory.new
  entries.each do |mode, name, oid|
    buf.write("#{mode.to_s(8)} #{name}".to_slice)
    buf.write_byte(0u8)
    buf.write(oid.to_bytes)
  end
  data = buf.to_slice
  {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Tree, data), data}
end

describe Git::Worktree::Diff do
  describe ".diff" do
    it "detects an added file" do
      blob_oid, blob_data = make_blob("hello\n")
      old_oid, old_data = make_tree([] of {UInt32, String, Git::Object::Id})
      new_oid, new_data = make_tree([{0o100644_u32, "README.md", blob_oid}])
      store = make_spec_store([
        {blob_oid, Git::Pack::ObjectType::Blob, blob_data},
        {old_oid, Git::Pack::ObjectType::Tree, old_data},
        {new_oid, Git::Pack::ObjectType::Tree, new_data},
      ])
      changes = Git::Worktree::Diff.diff(old_oid, new_oid, store)
      changes.size.should eq(1)
      changes[0].kind.should eq(Git::Worktree::Change::Kind::Added)
      changes[0].path.should eq("README.md")
      changes[0].oid.should eq(blob_oid)
    end

    it "detects a deleted file" do
      blob_oid, blob_data = make_blob("bye\n")
      old_oid, old_data = make_tree([{0o100644_u32, "gone.txt", blob_oid}])
      new_oid, new_data = make_tree([] of {UInt32, String, Git::Object::Id})
      store = make_spec_store([
        {blob_oid, Git::Pack::ObjectType::Blob, blob_data},
        {old_oid, Git::Pack::ObjectType::Tree, old_data},
        {new_oid, Git::Pack::ObjectType::Tree, new_data},
      ])
      changes = Git::Worktree::Diff.diff(old_oid, new_oid, store)
      changes.size.should eq(1)
      changes[0].kind.should eq(Git::Worktree::Change::Kind::Deleted)
      changes[0].path.should eq("gone.txt")
    end

    it "detects a modified file" do
      a_oid, a_data = make_blob("v1\n")
      b_oid, b_data = make_blob("v2\n")
      old_oid, old_data = make_tree([{0o100644_u32, "f.txt", a_oid}])
      new_oid, new_data = make_tree([{0o100644_u32, "f.txt", b_oid}])
      store = make_spec_store([
        {a_oid, Git::Pack::ObjectType::Blob, a_data},
        {b_oid, Git::Pack::ObjectType::Blob, b_data},
        {old_oid, Git::Pack::ObjectType::Tree, old_data},
        {new_oid, Git::Pack::ObjectType::Tree, new_data},
      ])
      changes = Git::Worktree::Diff.diff(old_oid, new_oid, store)
      changes.size.should eq(1)
      changes[0].kind.should eq(Git::Worktree::Change::Kind::Modified)
      changes[0].path.should eq("f.txt")
      changes[0].oid.should eq(b_oid)
    end

    it "handles nil old_tree (all files added)" do
      blob_oid, blob_data = make_blob("new\n")
      new_oid, new_data = make_tree([{0o100644_u32, "a.txt", blob_oid}])
      store = make_spec_store([
        {blob_oid, Git::Pack::ObjectType::Blob, blob_data},
        {new_oid, Git::Pack::ObjectType::Tree, new_data},
      ])
      changes = Git::Worktree::Diff.diff(nil, new_oid, store)
      changes.size.should eq(1)
      changes[0].kind.should eq(Git::Worktree::Change::Kind::Added)
      changes[0].path.should eq("a.txt")
    end

    it "recurses into a new subdirectory" do
      blob_oid, blob_data = make_blob("hi\n")
      sub_oid, sub_data = make_tree([{0o100644_u32, "main.cr", blob_oid}])
      old_oid, old_data = make_tree([] of {UInt32, String, Git::Object::Id})
      new_oid, new_data = make_tree([{0o40000_u32, "src", sub_oid}])
      store = make_spec_store([
        {blob_oid, Git::Pack::ObjectType::Blob, blob_data},
        {sub_oid, Git::Pack::ObjectType::Tree, sub_data},
        {old_oid, Git::Pack::ObjectType::Tree, old_data},
        {new_oid, Git::Pack::ObjectType::Tree, new_data},
      ])
      changes = Git::Worktree::Diff.diff(old_oid, new_oid, store)
      changes.size.should eq(1)
      changes[0].path.should eq("src/main.cr")
      changes[0].kind.should eq(Git::Worktree::Change::Kind::Added)
    end

    it "emits Deleted then Added when a file is replaced by a directory of the same name" do
      # Regression: previously the Changed branch only emitted Modified, which apply_changes
      # could not handle (EISDIR on File.write when a directory already exists at that path).
      inner_oid, inner_data = make_blob("inner\n")
      old_file_oid, old_file_data = make_blob("was a file\n")
      sub_oid, sub_data = make_tree([{0o100644_u32, "inner.txt", inner_oid}])
      old_oid, old_data = make_tree([{0o100644_u32, "item", old_file_oid}])
      new_oid, new_data = make_tree([{0o40000_u32, "item", sub_oid}])
      store = make_spec_store([
        {inner_oid, Git::Pack::ObjectType::Blob, inner_data},
        {old_file_oid, Git::Pack::ObjectType::Blob, old_file_data},
        {sub_oid, Git::Pack::ObjectType::Tree, sub_data},
        {old_oid, Git::Pack::ObjectType::Tree, old_data},
        {new_oid, Git::Pack::ObjectType::Tree, new_data},
      ])
      changes = Git::Worktree::Diff.diff(old_oid, new_oid, store)
      deleted = changes.select { |change| change.kind == Git::Worktree::Change::Kind::Deleted }
      added = changes.select { |change| change.kind == Git::Worktree::Change::Kind::Added }
      deleted.map(&.path).should contain("item")
      added.map(&.path).should contain("item/inner.txt")
    end

    it "emits subtree Deleted entries then Added file when a directory is replaced by a file" do
      inner_oid, inner_data = make_blob("inner\n")
      new_file_oid, new_file_data = make_blob("now a file\n")
      sub_oid, sub_data = make_tree([{0o100644_u32, "inner.txt", inner_oid}])
      old_oid, old_data = make_tree([{0o40000_u32, "item", sub_oid}])
      new_oid, new_data = make_tree([{0o100644_u32, "item", new_file_oid}])
      store = make_spec_store([
        {inner_oid, Git::Pack::ObjectType::Blob, inner_data},
        {new_file_oid, Git::Pack::ObjectType::Blob, new_file_data},
        {sub_oid, Git::Pack::ObjectType::Tree, sub_data},
        {old_oid, Git::Pack::ObjectType::Tree, old_data},
        {new_oid, Git::Pack::ObjectType::Tree, new_data},
      ])
      changes = Git::Worktree::Diff.diff(old_oid, new_oid, store)
      deleted = changes.select { |change| change.kind == Git::Worktree::Change::Kind::Deleted }
      added = changes.select { |change| change.kind == Git::Worktree::Change::Kind::Added }
      deleted.map(&.path).should contain("item/inner.txt")
      added.map(&.path).should contain("item")
    end

    it "returns empty for identical trees" do
      blob_oid, blob_data = make_blob("same\n")
      tree_oid, tree_data = make_tree([{0o100644_u32, "same.txt", blob_oid}])
      store = make_spec_store([
        {blob_oid, Git::Pack::ObjectType::Blob, blob_data},
        {tree_oid, Git::Pack::ObjectType::Tree, tree_data},
      ])
      Git::Worktree::Diff.diff(tree_oid, tree_oid, store).should be_empty
    end
  end
end
