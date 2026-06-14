module Git
  module CommitGraph
    # Wraps an ordered list of `CommitGraph::File` layers (oldest → newest).
    #
    # In an incremental chain, CDAT parent positions are *global* across all layers.
    # Chain handles the per-file base-count arithmetic needed to convert a global
    # graph position to the correct per-file local position and OID.
    struct Chain
      # Loads the commit-graph for *git_dir*.
      # Tries `.git/objects/info/commit-graphs/commit-graph-chain` first;
      # falls back to the single `.git/objects/info/commit-graph` file.
      # Returns `nil` when neither format is present.
      def self.load(git_dir : String, fs : FileSystem = FileSystem::Local.new) : Chain?
        chain_path = ::File.join(git_dir, "objects", "info", "commit-graphs", "commit-graph-chain")
        if fs.file?(chain_path)
          hashes = fs.read_lines(chain_path).map(&.strip).reject(&.empty?)
          files = hashes.compact_map do |hash|
            graph_path = ::File.join(git_dir, "objects", "info", "commit-graphs", "graph-#{hash}.graph")
            File.load(graph_path, fs)
          end
          return nil if files.empty?
          new(files)
        else
          single = ::File.join(git_dir, "objects", "info", "commit-graph")
          f = File.load(single, fs)
          f ? new([f]) : nil
        end
      end

      @files : Array(File)
      @base_counts : Array(Int32)

      def initialize(files : Array(File))
        @files = files
        @base_counts = compute_base_counts(files)
      end

      # Returns parent `Object::Id`s for *oid*, or `nil` if *oid* is absent from all layers.
      # Searches newest layer first so recently-added commits are found quickly.
      def parents_of(oid : Object::Id) : Array(Object::Id)?
        (@files.size - 1).downto(0) do |i|
          f = @files[i]
          local_pos = f.oid_position(oid)
          next unless local_pos
          return f.parent_graph_positions(local_pos).map { |graph_pos| oid_for_graph_position(graph_pos) }
        end
        nil
      end

      # Converts a global graph position *gp* to an `Object::Id` by finding the layer
      # whose commit range contains *gp*.
      private def oid_for_graph_position(graph_pos : UInt32) : Object::Id
        @files.each_with_index do |file, i|
          base = @base_counts[i]
          if graph_pos.to_i32 < base + file.count
            return file.oid_at(graph_pos.to_i32 - base)
          end
        end
        raise ProtocolError.new("Graph position #{graph_pos} out of range in commit-graph chain")
      end

      private def compute_base_counts(files : Array(File)) : Array(Int32)
        result = [] of Int32
        running = 0
        files.each { |file| result << running; running += file.count }
        result
      end
    end
  end
end
