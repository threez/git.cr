require "../../spec_helper"

# Stable OIDs that all start with 0x00 so they sort by the last two hex digits.
private def chain_oid(n : Int32) : Git::Object::Id
  Git.oid("00000000000000000000000000000000000000" + n.to_s.rjust(2, '0'))
end

describe Git::CommitGraph::Chain do
  describe ".load" do
    it "returns nil when no commit-graph exists" do
      dir = spec_tmp("cg-chain-nil")
      Dir.mkdir_p(File.join(dir, ".git"))
      begin
        Git::CommitGraph::Chain.load(File.join(dir, ".git")).should be_nil
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "wraps a single commit-graph file" do
      a = chain_oid(1)
      dir = spec_tmp("cg-chain-single")
      info = File.join(dir, ".git", "objects", "info")
      Dir.mkdir_p(info)
      begin
        File.write(File.join(info, "commit-graph"),
          build_spec_commit_graph([{a, [] of Git::Object::Id}]))
        chain = Git::CommitGraph::Chain.load(File.join(dir, ".git")) || raise "expected commit-graph chain"
        chain.parents_of(a).should eq([] of Git::Object::Id)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "reads a commit-graph-chain directory and resolves parents" do
      a = chain_oid(1)
      b = chain_oid(2)
      c = chain_oid(3)
      dir = spec_tmp("cg-chain-dir")
      graphs_dir = File.join(dir, ".git", "objects", "info", "commit-graphs")
      Dir.mkdir_p(graphs_dir)
      begin
        # base layer: A (root), B (parent A); sorted → A at pos 0, B at pos 1
        base_bytes = build_spec_commit_graph([
          {a, [] of Git::Object::Id},
          {b, [a]},
        ])
        # tip layer: C (parent B); B's global position = 1 (from base)
        tip_bytes = build_spec_commit_graph(
          [{c, [b]}],
          extra_positions: {b => 1}
        )
        File.write(File.join(graphs_dir, "graph-base.graph"), base_bytes)
        File.write(File.join(graphs_dir, "graph-tip.graph"), tip_bytes)
        File.write(File.join(graphs_dir, "commit-graph-chain"), "base\ntip\n")

        chain = Git::CommitGraph::Chain.load(File.join(dir, ".git")) || raise "expected commit-graph chain"
        chain.parents_of(a).should eq([] of Git::Object::Id)
        chain.parents_of(b).should eq([a])
        chain.parents_of(c).should eq([b])
        chain.parents_of(chain_oid(99)).should be_nil
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "#parents_of" do
    it "resolves cross-file parent references in a two-layer chain" do
      a = chain_oid(1)
      b = chain_oid(2)
      c = chain_oid(3)

      # base layer: A at global pos 0 (root), B at global pos 1 (parent A)
      base_bytes = build_spec_commit_graph([
        {a, [] of Git::Object::Id},
        {b, [a]},
      ])
      # tip layer: C with parent B at global position 1 (in base layer)
      tip_bytes = build_spec_commit_graph(
        [{c, [b]}],
        extra_positions: {b => 1}
      )

      base_file = Git::CommitGraph::File.new(base_bytes)
      tip_file = Git::CommitGraph::File.new(tip_bytes)
      chain = Git::CommitGraph::Chain.new([base_file, tip_file])

      chain.parents_of(c).should eq([b]) # cross-file reference
      chain.parents_of(b).should eq([a]) # base-layer commit
      chain.parents_of(a).should eq([] of Git::Object::Id)
      chain.parents_of(chain_oid(99)).should be_nil
    end
  end
end
