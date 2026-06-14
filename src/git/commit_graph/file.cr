module Git
  module CommitGraph
    # Reads a `.git/objects/info/commit-graph` binary file and provides O(1)
    # parent lookups for BFS ancestry checks.
    #
    # Only the single-file v1 SHA-1 format is supported (not incremental chains).
    struct File
      MAGIC           = "CGPH"
      NO_PARENT       = 0x70000000_u32
      EXTRA_EDGE_FLAG = 0x80000000_u32
      EDGE_LAST       = 0x80000000_u32

      CHUNK_OIDF = 0x4F494446_u32
      CHUNK_OIDL = 0x4F49444C_u32
      CHUNK_CDAT = 0x43444154_u32
      CHUNK_EDGE = 0x45444745_u32

      # Loads and parses the commit-graph file at *path*.
      # Returns `nil` when the file does not exist.
      def self.load(path : String, fs : FileSystem = FileSystem::Local.new) : CommitGraph::File?
        return nil unless fs.file?(path)
        new(fs.read(path).to_slice)
      end

      # Returns the parent `Object::Id`s for *oid*, or `nil` if *oid* is not in the graph.
      def parents_of(oid : Object::Id) : Array(Object::Id)?
        pos = oid_position(oid)
        return nil if pos.nil?
        parents_at(pos)
      end

      @data : Bytes
      @oidf_off : Int32
      @oidl_off : Int32
      @cdat_off : Int32
      @edge_off : Int32?
      # Number of commits indexed in this commit-graph file.
      getter count : Int32

      def initialize(data : Bytes)
        @data = data
        raise ProtocolError.new("Not a commit-graph file: bad magic") unless String.new(@data[0, 4]) == MAGIC

        num_chunks = @data[6].to_i32

        oidf_off = nil.as(Int32?)
        oidl_off = nil.as(Int32?)
        cdat_off = nil.as(Int32?)
        edge_off = nil.as(Int32?)

        num_chunks.times do |i|
          table_off = 8 + i * 12
          chunk_id = read_u32(table_off)
          chunk_off = read_u64(table_off + 4).to_i32
          case chunk_id
          when CHUNK_OIDF then oidf_off = chunk_off
          when CHUNK_OIDL then oidl_off = chunk_off
          when CHUNK_CDAT then cdat_off = chunk_off
          when CHUNK_EDGE then edge_off = chunk_off
          end
        end

        raise ProtocolError.new("Commit-graph missing OIDF chunk") unless oidf_off
        raise ProtocolError.new("Commit-graph missing OIDL chunk") unless oidl_off
        raise ProtocolError.new("Commit-graph missing CDAT chunk") unless cdat_off

        @oidf_off = oidf_off
        @oidl_off = oidl_off
        @cdat_off = cdat_off
        @edge_off = edge_off
        @count = read_u32(oidf_off + 255 * 4).to_i32
      end

      # Returns the OIDL position of *oid*, or nil if not present.
      def oid_position(oid : Object::Id) : Int32?
        oid_bytes = oid.to_bytes
        b = oid_bytes[0].to_i32
        lo = b == 0 ? 0 : read_u32(@oidf_off + (b - 1) * 4).to_i32
        hi = read_u32(@oidf_off + b * 4).to_i32

        while lo < hi
          mid = (lo + hi) // 2
          mid_oid = @data[@oidl_off + mid * 20, 20]
          cmp = compare_bytes(oid_bytes, mid_oid)
          if cmp < 0
            hi = mid
          elsif cmp > 0
            lo = mid + 1
          else
            return mid
          end
        end
        nil
      end

      # Returns raw CDAT parent graph positions for the commit at local OIDL position *pos*.
      # Positions are global across a chain — callers with multi-file context must resolve
      # them via their own oid_for_graph_position logic.
      def parent_graph_positions(local_pos : Int32) : Array(UInt32)
        entry_off = @cdat_off + local_pos * 36
        p1 = read_u32(entry_off + 20)
        return [] of UInt32 if p1 == NO_PARENT

        p2 = read_u32(entry_off + 24)
        if p2 == NO_PARENT
          [p1]
        elsif p2 & EXTRA_EDGE_FLAG != 0
          edge_off = @edge_off || raise ProtocolError.new("Commit-graph references EDGE chunk but none is present")
          positions = [p1]
          i = (p2 & ~EXTRA_EDGE_FLAG).to_i32
          loop do
            entry = read_u32(edge_off + i * 4)
            positions << (entry & ~EDGE_LAST)
            break if entry & EDGE_LAST != 0
            i += 1
          end
          positions
        else
          [p1, p2]
        end
      end

      # Returns the Object::Id stored at local OIDL position *pos*.
      def oid_at(pos : Int32) : Object::Id
        Object::Id.from_bytes(@data[@oidl_off + pos * 20, 20])
      end

      # Decodes parent Object::Ids for the commit at OIDL position *pos*.
      # Valid only for single-file graphs; Chain uses parent_graph_positions instead.
      private def parents_at(pos : Int32) : Array(Object::Id)
        parent_graph_positions(pos).map { |graph_pos| oid_at(graph_pos.to_i32) }
      end

      private def read_u32(off : Int32) : UInt32
        IO::ByteFormat::BigEndian.decode(UInt32, @data[off, 4])
      end

      private def read_u64(off : Int32) : UInt64
        IO::ByteFormat::BigEndian.decode(UInt64, @data[off, 8])
      end

      private def compare_bytes(a : Bytes, b : Bytes) : Int32
        20.times do |i|
          diff = a[i].to_i32 - b[i].to_i32
          return diff unless diff == 0
        end
        0
      end
    end
  end
end
