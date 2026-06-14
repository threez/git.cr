require "../../spec_helper"
require "file_utils"

describe Git::Pack::Scanner do
  it "returns the correct number of RawObjects" do
    dir = spec_tmp("scanner-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "test.pack")

    blob1 = "hello\n".to_slice
    blob2 = "world\n".to_slice
    oid1 = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, blob1)
    oid2 = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, blob2)
    write_spec_pack(path, [{oid1, Git::Pack::ObjectType::Blob, blob1},
                           {oid2, Git::Pack::ObjectType::Blob, blob2}])

    objects = Git::Pack::Scanner.scan(path, 2)
    objects.size.should eq(2)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "raises Pack::FileError when an object declares an uncompressed size larger than Int32::MAX" do
    # Regression: previously size.to_i32 could overflow or Bytes.new could attempt
    # a multi-GB allocation from an attacker-controlled varint in the pack header.
    dir = spec_tmp("scanner-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "huge_size.pack")

    # Craft a pack with one object whose declared uncompressed size is 2^31 (> Int32::MAX).
    # Object header: type=blob(3), size=2^31=0x80000000.
    #   First byte: more=1 (bit7), type=3 (bits6-4), size_low4=0 → 0xB0
    #   Next bytes encode remaining size 0x8000000 in 7-bit groups with continuation:
    #   0x8000000 → [0x80, 0x80, 0x80, 0x40]
    buf = IO::Memory.new
    buf.write("PACK".to_slice)
    spec_write_be32(buf, 2_u32) # version
    spec_write_be32(buf, 1_u32) # object count = 1
    buf.write_byte(0xB0u8)      # more=1, type=blob(3), size_low=0
    buf.write_byte(0x80u8)      # size bits 4-10 = 0, more
    buf.write_byte(0x80u8)      # size bits 11-17 = 0, more
    buf.write_byte(0x80u8)      # size bits 18-24 = 0, more
    buf.write_byte(0x40u8)      # size bits 25-31 = 64 → total = 64 * 2^25 = 2^31
    buf.write(Bytes.new(20))    # trailing SHA-1 placeholder
    File.write(path, buf.to_slice)

    expect_raises(Git::Pack::FileError, /invalid uncompressed size/) do
      Git::Pack::Scanner.scan(path, 1)
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "returns RawObjects with the correct type and decompressed data" do
    dir = spec_tmp("scanner-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "test.pack")

    data = "crystal git scanner test\n".to_slice
    oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data)
    write_spec_pack(path, [{oid, Git::Pack::ObjectType::Blob, data}])

    objects = Git::Pack::Scanner.scan(path, 1)
    objects[0].type.should eq(Git::Pack::ObjectType::Blob)
    objects[0].data.should eq(data)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
