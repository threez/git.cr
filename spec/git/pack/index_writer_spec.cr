require "../../spec_helper"
require "file_utils"

describe Git::Pack::IndexWriter do
  it "writes a .idx file adjacent to the .pack file" do
    dir = spec_tmp("idxwriter-spec")
    Dir.mkdir_p(dir)
    pack_path = File.join(dir, "test.pack")

    data = "index writer test\n".to_slice
    oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data)
    write_spec_pack(pack_path, [{oid, Git::Pack::ObjectType::Blob, data}])

    resolver = Git::Pack::Resolver.new(pack_path, 1)
    resolver.resolve!
    Git::Pack::IndexWriter.write_for_pack(resolver.sha1_map.values, pack_path)

    idx_path = pack_path.sub(/\.pack$/, ".idx")
    File.exists?(idx_path).should be_true
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "emits the OFS64 large-offset table for pack offsets >= 2^31" do
    # Regression: previously pack_offset.to_u32 raised OverflowError for offsets >= 2^31.
    # The fix writes an MSB-set 32-bit index into an appended OFS64 table.
    dir = spec_tmp("idxwriter-spec")
    Dir.mkdir_p(dir)
    pack_path = File.join(dir, "test.pack")

    # Write a real pack (required for read_pack_trailing_sha1 in write_for_pack).
    data = "ofs64 test\n".to_slice
    small_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data)
    write_spec_pack(pack_path, [{small_oid, Git::Pack::ObjectType::Blob, data}])

    # Resolve to get a real ResolvedObject at a small pack offset.
    resolver = Git::Pack::Resolver.new(pack_path, 1)
    resolver.resolve!
    small_obj = resolver.sha1_map.values.first

    # Synthesise a second object with pack_offset >= 2^31.
    large_offset = 0x80000001_i64
    large_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, "large\n".to_slice)
    large_obj = Git::Pack::ResolvedObject.new(large_oid, Git::Pack::ObjectType::Blob, "large\n".to_slice, 0u32, large_offset)

    Git::Pack::IndexWriter.write_for_pack([small_obj, large_obj], pack_path)
    idx_path = pack_path.sub(/\.pack$/, ".idx")

    # Parse the idx binary to verify the OFS64 table.
    # v2 idx layout: 8 (header) + 256*4 (fanout) + n*20 (SHA-1s) + n*4 (CRC32s) + n*4 (offsets) + OFS64...
    n = 2
    offsets_start = 8 + 256 * 4 + n * 20 + n * 4
    ofs64_start = offsets_start + n * 4

    ::File.open(idx_path, "rb") do |file|
      # Find which slot has the MSB set (the large-offset object).
      file.seek(offsets_start, IO::Seek::Set)
      entries = Array(UInt32).new(n) { file.read_bytes(UInt32, IO::ByteFormat::BigEndian) }
      large_entry = entries.find { |entry| entry & 0x80000000_u32 != 0 }
      large_entry.should_not be_nil
      ofs64_index = (large_entry.not_nil! & 0x7FFFFFFF_u32).to_i32 # ameba:disable Lint/NotNil

      # Read the OFS64 entry at that index.
      file.seek(ofs64_start + ofs64_index * 8, IO::Seek::Set)
      high = file.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i64
      low = file.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i64
      recovered = (high << 32) | low
      recovered.should eq(large_offset)
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "written index reports the correct object count" do
    dir = spec_tmp("idxwriter-spec")
    Dir.mkdir_p(dir)
    pack_path = File.join(dir, "test.pack")

    objects = (1..3).map do |i|
      d = "object #{i}\n".to_slice
      {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, d), Git::Pack::ObjectType::Blob, d}
    end
    write_spec_pack(pack_path, objects)

    resolver = Git::Pack::Resolver.new(pack_path, 3)
    resolver.resolve!
    Git::Pack::IndexWriter.write_for_pack(resolver.sha1_map.values, pack_path)

    idx_path = pack_path.sub(/\.pack$/, ".idx")
    Git::Pack::Index.read_count(idx_path).should eq(3)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
