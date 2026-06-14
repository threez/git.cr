require "../../spec_helper"

describe Git::Object::Commit do
  commit_text = <<-COMMIT
    tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
    parent da39a3ee5e6b4b0d3255bfef95601890afd80709
    author Alice <alice@example.com> 1700000000 +0000
    committer Bob <bob@example.com> 1700000001 +0000

    Initial commit

    Second paragraph.
    COMMIT

  describe ".parse" do
    it "parses the tree SHA" do
      commit = Git::Object::Commit.parse(commit_text.to_slice)
      commit.tree.to_hex.should eq("4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    end

    it "parses parent SHA" do
      commit = Git::Object::Commit.parse(commit_text.to_slice)
      commit.parents.size.should eq(1)
      commit.parents[0].to_hex.should eq("da39a3ee5e6b4b0d3255bfef95601890afd80709")
    end

    it "parses author" do
      commit = Git::Object::Commit.parse(commit_text.to_slice)
      commit.author.should eq("Alice <alice@example.com> 1700000000 +0000")
    end

    it "parses committer" do
      commit = Git::Object::Commit.parse(commit_text.to_slice)
      commit.committer.should eq("Bob <bob@example.com> 1700000001 +0000")
    end

    it "parses the commit message" do
      commit = Git::Object::Commit.parse(commit_text.to_slice)
      commit.message.should contain("Initial commit")
    end

    it "handles a commit with no parents" do
      text = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor A <a@b> 0 +0000\ncommitter A <a@b> 0 +0000\n\nroot commit\n"
      commit = Git::Object::Commit.parse(text.to_slice)
      commit.parents.should be_empty
    end

    it "raises on missing tree line" do
      text = "author A <a@b> 0 +0000\n\nmessage\n"
      expect_raises(Git::ProtocolError, /tree/) do
        Git::Object::Commit.parse(text.to_slice)
      end
    end
  end
end
