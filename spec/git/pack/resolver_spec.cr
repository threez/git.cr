require "../../spec_helper"
require "file_utils"
require "compress/zlib"

describe Git::Pack::Resolver do
  it "populates sha1_map after resolve!" do
    dir = spec_tmp("resolver-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "test.pack")

    data = "resolver test blob\n".to_slice
    oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data)
    write_spec_pack(path, [{oid, Git::Pack::ObjectType::Blob, data}])

    resolver = Git::Pack::Resolver.new(path, 1)
    resolver.resolve!
    resolver.sha1_map.size.should eq(1)
    resolver.sha1_map.has_key?(oid).should be_true
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "[] returns {type, data} for a resolved object" do
    dir = spec_tmp("resolver-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "test.pack")

    data = "lookup test\n".to_slice
    oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data)
    write_spec_pack(path, [{oid, Git::Pack::ObjectType::Blob, data}])

    resolver = Git::Pack::Resolver.new(path, 1)
    resolver.resolve!
    resolver[oid].should eq({Git::Pack::ObjectType::Blob, data})
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "thin pack becomes self-contained after resolve!(store) — re-open without store succeeds" do
    # Regression: previously external REF_DELTA bases were resolved in memory but not
    # persisted to disk, so a second Store.new raised "broken delta chain".
    dir = spec_tmp("resolver-spec")
    Dir.mkdir_p(dir)
    pack_path = File.join(dir, "thin.pack")
    idx_path = pack_path.sub(/\.pack$/, ".idx")

    # The base blob exists only in the store (not in the thin pack).
    base_data = "base\n".to_slice
    base_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, base_data)
    store = make_spec_store([{base_oid, Git::Pack::ObjectType::Blob, base_data}])

    # Delta: COPY 5 bytes from base then ADD "!\n" → result = "base\n!\n" (7 bytes).
    # The result has a different SHA-1 from the base, so sha1_map will have 2 distinct entries.
    # Format: [base_size, result_size, COPY(offset=0,len=5), ADD(len=2,"!\n")]
    delta_bytes = Bytes[0x05u8, 0x07u8, 0x91u8, 0x00u8, 0x05u8, 0x02u8, 0x21u8, 0x0Au8]

    # Compress the delta.
    zbuf = IO::Memory.new
    Compress::Zlib::Writer.open(zbuf, &.write(delta_bytes))
    compressed_delta = zbuf.to_slice

    # Craft the thin pack: 1 REF_DELTA object referencing base_oid.
    # REF_DELTA type = 7; size = 8 (uncompressed delta size = 8 bytes).
    # First byte: bit7=0 (no more), bits6-4=type=7=0b111, bits3-0=size=8=0b1000 → 0x78
    buf = IO::Memory.new
    buf.write("PACK".to_slice)
    spec_write_be32(buf, 2_u32)  # version
    spec_write_be32(buf, 1_u32)  # object count = 1
    buf.write_byte(0x78u8)       # REF_DELTA, uncompressed delta size = 8
    buf.write(base_oid.to_bytes) # 20-byte base SHA-1
    buf.write(compressed_delta)  # zlib-compressed delta
    buf.write(Bytes.new(20))     # trailing SHA-1 placeholder (scanner doesn't validate)
    File.write(pack_path, buf.to_slice)

    # First resolve: fetches base from store, resolves delta, appends base to pack.
    resolver1 = Git::Pack::Resolver.new(pack_path, 1)
    resolver1.resolve!(store)
    resolver1.sha1_map.has_key?(base_oid).should be_true
    Git::Pack::IndexWriter.write_for_pack(resolver1.sha1_map.values, pack_path)

    # Second resolve: no store — pack must be self-contained.
    count2 = Git::Pack::Index.read_count(idx_path)
    count2.should eq(2) # original result object + appended base
    resolver2 = Git::Pack::Resolver.new(pack_path, count2)
    resolver2.resolve! # must not raise "broken delta chain"
    resolver2[base_oid].should_not be_nil
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "each yields all resolved objects" do
    dir = spec_tmp("resolver-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "test.pack")

    blobs = [{"a\n".to_slice}, {"b\n".to_slice}].map do |(d)|
      {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, d), Git::Pack::ObjectType::Blob, d}
    end
    write_spec_pack(path, blobs)

    resolver = Git::Pack::Resolver.new(path, 2)
    resolver.resolve!

    count = 0
    resolver.each { |_sha1, _type, _data| count += 1 }
    count.should eq(2)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
