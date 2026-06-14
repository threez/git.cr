require "../../spec_helper"

private def build_tree_entry(mode : String, name : String, sha_hex : String) : Bytes
  sha = sha_hex.scan(/../).map(&.[0].to_u8(16)).to_a
  entry = IO::Memory.new
  entry.write(mode.to_slice)
  entry.write_byte(0x20u8)
  entry.write(name.to_slice)
  entry.write_byte(0x00u8)
  entry.write(Bytes.new(20) { |i| sha[i].to_u8 })
  entry.to_slice
end

describe Git::Object::Tree do
  sha = "da39a3ee5e6b4b0d3255bfef95601890afd80709"

  describe ".parse" do
    it "parses a single blob entry" do
      data = build_tree_entry("100644", "README.md", sha)
      entries = Git::Object::Tree.parse(data)
      entries.size.should eq(1)
      entries[0].name.should eq("README.md")
      entries[0].mode.should eq(0o100644_u32)
      entries[0].oid.to_hex.should eq(sha)
    end

    it "parses a directory entry" do
      data = build_tree_entry("40000", "src", sha)
      entries = Git::Object::Tree.parse(data)
      entries[0].directory?.should be_true
      entries[0].name.should eq("src")
    end

    it "parses an executable file entry" do
      data = build_tree_entry("100755", "run.sh", sha)
      entries = Git::Object::Tree.parse(data)
      entries[0].executable?.should be_true
    end

    it "parses a symlink entry" do
      data = build_tree_entry("120000", "link", sha)
      entries = Git::Object::Tree.parse(data)
      entries[0].symlink?.should be_true
    end

    it "parses multiple entries" do
      data1 = build_tree_entry("100644", "a.txt", sha)
      data2 = build_tree_entry("100644", "b.txt", sha)
      entries = Git::Object::Tree.parse(data1 + data2)
      entries.size.should eq(2)
      entries[0].name.should eq("a.txt")
      entries[1].name.should eq("b.txt")
    end

    it "returns an empty array for empty tree data" do
      Git::Object::Tree.parse(Bytes.empty).should be_empty
    end
  end
end
