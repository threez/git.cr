require "../../spec_helper"

# Helpers: stable OIDs that sort predictably (all start with 0x00)
private def cg_oid(n : Int32) : Git::Object::Id
  Git.oid("00000000000000000000000000000000000000" + n.to_s.rjust(2, '0'))
end

describe Git::CommitGraph::File do
  describe ".load" do
    it "returns nil when the file does not exist" do
      Git::CommitGraph::File.load("/nonexistent/path/commit-graph").should be_nil
    end
  end

  describe "#initialize" do
    it "raises ProtocolError on bad magic" do
      bad = Bytes.new(8, 0_u8)
      expect_raises(Git::ProtocolError, /magic/) do
        Git::CommitGraph::File.new(bad)
      end
    end
  end

  describe "#parents_of" do
    it "returns nil for an OID not in the graph" do
      a = cg_oid(1)
      data = build_spec_commit_graph([{a, [] of Git::Object::Id}])
      graph = Git::CommitGraph::File.new(data)
      graph.parents_of(cg_oid(99)).should be_nil
    end

    it "returns empty array for a root commit (no parents)" do
      a = cg_oid(1)
      data = build_spec_commit_graph([{a, [] of Git::Object::Id}])
      graph = Git::CommitGraph::File.new(data)
      graph.parents_of(a).should eq([] of Git::Object::Id)
    end

    it "returns one parent for a linear commit" do
      a = cg_oid(1)
      b = cg_oid(2)
      data = build_spec_commit_graph([
        {a, [] of Git::Object::Id},
        {b, [a]},
      ])
      graph = Git::CommitGraph::File.new(data)
      graph.parents_of(b).should eq([a])
      graph.parents_of(a).should eq([] of Git::Object::Id)
    end

    it "returns two parents for a merge commit" do
      a = cg_oid(1)
      b = cg_oid(2)
      c = cg_oid(3)
      data = build_spec_commit_graph([
        {a, [] of Git::Object::Id},
        {b, [] of Git::Object::Id},
        {c, [a, b]},
      ])
      graph = Git::CommitGraph::File.new(data)
      graph.parents_of(c).should eq([a, b])
    end

    it "handles commits at OIDL boundary positions (first and last)" do
      # cg_oid(1) sorts before cg_oid(9) — verify both extremes are found
      low = cg_oid(1)
      high = cg_oid(9)
      data = build_spec_commit_graph([
        {low, [] of Git::Object::Id},
        {high, [low]},
      ])
      graph = Git::CommitGraph::File.new(data)
      graph.parents_of(low).should eq([] of Git::Object::Id)
      graph.parents_of(high).should eq([low])
    end
  end
end
