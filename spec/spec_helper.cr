require "spec"
require "compress/zlib"
require "file_utils"
require "../src/git"

SPEC_TMP = File.expand_path(File.join(__DIR__, "tmp"))
Dir.mkdir_p(SPEC_TMP)

# Returns a unique path under spec/tmp/ for use as a per-test temp directory.
# The caller is responsible for Dir.mkdir_p and FileUtils.rm_rf cleanup.
def spec_tmp(prefix : String) : String
  File.join(SPEC_TMP, "#{prefix}-#{Random::Secure.hex(6)}")
end

# Builds a valid (non-delta) pack file from an array of {oid, type, data} triples.
# The trailing SHA1 is 20 zero bytes — acceptable for tests since the scanner
# doesn't validate it and IndexWriter reads it verbatim.
def write_spec_pack(path : String, objects : Array({Git::Object::Id, Git::Pack::ObjectType, Bytes})) : Nil
  buf = IO::Memory.new
  buf.write("PACK".to_slice)
  spec_write_be32(buf, 2_u32)
  spec_write_be32(buf, objects.size.to_u32)
  objects.each { |_oid, type, data| spec_write_pack_object(buf, type, data) }
  buf.write(Bytes.new(20))
  File.write(path, buf.to_slice)
end

def spec_write_be32(io : IO, v : UInt32) : Nil
  b = Bytes.new(4)
  IO::ByteFormat::BigEndian.encode(v, b)
  io.write(b)
end

def spec_write_be64(io : IO, v : UInt64) : Nil
  b = Bytes.new(8)
  IO::ByteFormat::BigEndian.encode(v, b)
  io.write(b)
end

def spec_write_pack_object(io : IO, type : Git::Pack::ObjectType, data : Bytes) : Nil
  type_int = type.value.to_u64
  size = data.size.to_u64
  first = ((type_int & 0x7) << 4) | (size & 0xf)
  size >>= 4
  first |= 0x80 if size > 0
  io.write_byte(first.to_u8)
  while size > 0
    b = (size & 0x7f).to_u8
    size >>= 7
    b |= 0x80 if size > 0
    io.write_byte(b)
  end
  zbuf = IO::Memory.new
  Compress::Zlib::Writer.open(zbuf, &.write(data))
  io.write(zbuf.to_slice)
end

# Builds a minimal commit-graph binary from *entries* (unsorted {oid, parent_oids} pairs).
# Only supports commits with 0, 1, or 2 parents (no octopus / EDGE chunk).
# The trailing SHA-1 footer is zeroed — sufficient for tests since `File` does not
# validate it.
def build_spec_commit_graph(
  entries : Array({Git::Object::Id, Array(Git::Object::Id)}),
  extra_positions : Hash(Git::Object::Id, Int32) = {} of Git::Object::Id => Int32,
) : Bytes
  no_parent = Git::CommitGraph::File::NO_PARENT

  # Sort by OID bytes so positions match the OIDL order
  sorted = entries.sort_by { |oid, _| oid.to_bytes.to_a }
  n = sorted.size
  pos_of = sorted.each_with_index.to_h { |(oid, _), i| {oid, i} }

  # Compute chunk byte offsets
  header_size = 8
  chunk_table_size = 4 * 12                 # 3 chunks (OIDF, OIDL, CDAT) + 1 terminator
  oidf_off = header_size + chunk_table_size # 56
  oidl_off = oidf_off + 256 * 4             # 56 + 1024 = 1080
  cdat_off = oidl_off + n * 20
  total_size = cdat_off + n * 36 + 20 # +20 for SHA-1 footer

  buf = IO::Memory.new

  # Header
  buf.write("CGPH".to_slice)
  buf.write_byte(1_u8) # version
  buf.write_byte(1_u8) # hash_version (SHA-1)
  buf.write_byte(3_u8) # num_chunks
  buf.write_byte(0_u8) # base_graphs_count

  # Chunk lookup table
  spec_write_be32(buf, 0x4F494446_u32); spec_write_be64(buf, oidf_off.to_u64) # OIDF
  spec_write_be32(buf, 0x4F49444C_u32); spec_write_be64(buf, oidl_off.to_u64) # OIDL
  spec_write_be32(buf, 0x43444154_u32); spec_write_be64(buf, cdat_off.to_u64) # CDAT
  spec_write_be32(buf, 0_u32); spec_write_be64(buf, total_size.to_u64)        # terminator

  # OIDF chunk: cumulative fanout per first byte
  counts = Array(UInt32).new(256, 0_u32)
  sorted.each { |oid, _| counts[oid.to_bytes[0]] += 1 }
  cumulative = 0_u32
  256.times do |i|
    cumulative += counts[i]
    spec_write_be32(buf, cumulative)
  end

  # OIDL chunk: sorted 20-byte OIDs
  sorted.each { |oid, _| buf.write(oid.to_bytes) }

  # CDAT chunk: 36 bytes per commit
  # Parent positions are global graph positions: check extra_positions first (for
  # cross-file references in chain tests), then fall back to local pos_of.
  resolve_parent = ->(oid : Git::Object::Id?) {
    oid ? (extra_positions[oid]?.try(&.to_u32) || pos_of[oid].to_u32) : no_parent
  }
  sorted.each do |_oid, parents|
    buf.write(Bytes.new(20)) # tree OID (zeros)
    spec_write_be32(buf, resolve_parent.call(parents[0]?))
    spec_write_be32(buf, resolve_parent.call(parents[1]?))
    buf.write(Bytes.new(8)) # generation/date (zeros)
  end

  # Footer SHA-1 (zeros — not validated)
  buf.write(Bytes.new(20))

  buf.to_slice
end

# Creates an in-memory ObjectStore from an array of {oid, type, data} triples.
def make_spec_store(objects : Array({Git::Object::Id, Git::Pack::ObjectType, Bytes})) : Git::Object::Store
  map = Hash(Git::Object::Id, {Git::Pack::ObjectType, Bytes}).new
  objects.each { |oid, type, data| map[oid] = {type, data} }
  Git::Object::Store.new(map)
end
