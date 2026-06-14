require "../spec_helper"

private def make_commit(message : String, parent_oids : Array(Git::Object::Id) = [] of Git::Object::Id) : {Git::Object::Id, Bytes}
  lines = String::Builder.new
  lines << "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
  parent_oids.each { |parent_oid| lines << "parent #{parent_oid.to_hex}\n" }
  lines << "author T <t@t> 0 +0000\ncommitter T <t@t> 0 +0000\n\n#{message}\n"
  data = lines.to_s.to_slice
  {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Commit, data), data}
end

describe Git::CommitGraph do
  describe ".ancestor?" do
    it "returns true when tip == ancestor" do
      root_oid, root_data = make_commit("root")
      store = make_spec_store([{root_oid, Git::Pack::ObjectType::Commit, root_data}])
      Git::CommitGraph.ancestor?(root_oid, root_oid, store).should be_true
    end

    it "returns true for direct parent" do
      root_oid, root_data = make_commit("root")
      child_oid, child_data = make_commit("child", [root_oid])
      store = make_spec_store([
        {root_oid, Git::Pack::ObjectType::Commit, root_data},
        {child_oid, Git::Pack::ObjectType::Commit, child_data},
      ])
      Git::CommitGraph.ancestor?(child_oid, root_oid, store).should be_true
      Git::CommitGraph.ancestor?(root_oid, child_oid, store).should be_false
    end

    it "returns true for transitive ancestor" do
      a_oid, a_data = make_commit("A")
      b_oid, b_data = make_commit("B", [a_oid])
      c_oid, c_data = make_commit("C", [b_oid])
      store = make_spec_store([
        {a_oid, Git::Pack::ObjectType::Commit, a_data},
        {b_oid, Git::Pack::ObjectType::Commit, b_data},
        {c_oid, Git::Pack::ObjectType::Commit, c_data},
      ])
      Git::CommitGraph.ancestor?(c_oid, a_oid, store).should be_true
      Git::CommitGraph.ancestor?(a_oid, c_oid, store).should be_false
    end

    it "uses commit-graph file for parent lookups (no pack objects consulted)" do
      a_oid, _ = make_commit("A")
      b_oid, _ = make_commit("B", [a_oid])
      c_oid, _ = make_commit("C", [b_oid])
      dir = spec_tmp("cg-commit-graph")
      begin
        # Build graph and write it into the temp .git directory
        info_dir = File.join(dir, ".git", "objects", "info")
        Dir.mkdir_p(info_dir)
        graph_path = File.join(info_dir, "commit-graph")
        File.write(graph_path, build_spec_commit_graph([
          {a_oid, [] of Git::Object::Id},
          {b_oid, [a_oid]},
          {c_oid, [b_oid]},
        ]))

        file = Git::CommitGraph::File.load(graph_path) || raise "expected commit-graph file"
        graph = Git::CommitGraph::Chain.new([file])

        # Use an empty store to prove the graph — not the pack — is consulted
        empty_store = make_spec_store([] of {Git::Object::Id, Git::Pack::ObjectType, Bytes})
        Git::CommitGraph.ancestor?(c_oid, a_oid, empty_store, nil, graph).should be_true
        Git::CommitGraph.ancestor?(a_oid, c_oid, empty_store, nil, graph).should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "resolves ancestors from new_objects resolver" do
      root_oid, root_data = make_commit("root")
      child_oid, child_data = make_commit("child", [root_oid])
      store = make_spec_store([{root_oid, Git::Pack::ObjectType::Commit, root_data}])

      new_pack_dir = spec_tmp("cg-new")
      Dir.mkdir_p(new_pack_dir)
      new_pack = File.join(new_pack_dir, "p.pack")
      write_spec_pack(new_pack, [{child_oid, Git::Pack::ObjectType::Commit, child_data}])
      new_resolver = Git::Pack::Resolver.new(new_pack, 1)
      new_resolver.resolve!(store)

      Git::CommitGraph.ancestor?(child_oid, root_oid, store, new_resolver).should be_true
      FileUtils.rm_rf(new_pack_dir)
    end
  end
end
