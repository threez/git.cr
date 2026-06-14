require "../../spec_helper"
require "file_utils"
require "digest/sha1"

private def build_pack_header(object_count : UInt32 = 0_u32) : IO::Memory
  mem = IO::Memory.new
  magic = "PACK".to_slice
  version_buf = Bytes.new(4); IO::ByteFormat::BigEndian.encode(2_u32, version_buf)
  count_buf = Bytes.new(4); IO::ByteFormat::BigEndian.encode(object_count, count_buf)
  mem.write(magic)
  mem.write(version_buf)
  mem.write(count_buf)
  # Compute and append the trailing SHA-1 over the header bytes.
  digest = Digest::SHA1.new
  digest.update(magic)
  digest.update(version_buf)
  digest.update(count_buf)
  mem.write(digest.final)
  mem.rewind
  mem
end

private def with_tmpdir(& : String ->) : Nil
  dir = spec_tmp("crystal-git-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Git::Pack::File do
  describe ".receive" do
    it "writes a valid packfile and returns the object count" do
      with_tmpdir do |dir|
        path = File.join(dir, "test.pack")
        count = Git::Pack::File.receive(build_pack_header(42_u32), path)
        count.should eq(42)
        File.exists?(path).should be_true
        File.open(path, "rb") do |file|
          magic = Bytes.new(4)
          file.read_fully(magic)
          String.new(magic).should eq("PACK")
        end
      end
    end

    it "raises Pack::FileError when the trailing SHA-1 does not match" do
      # Regression: previously the pack was streamed to disk without validating
      # the trailing checksum, allowing a tampered or truncated pack to be accepted.
      with_tmpdir do |dir|
        mem = IO::Memory.new
        mem.write("PACK".to_slice)
        mem.write_bytes(2_u32, IO::ByteFormat::BigEndian) # version
        mem.write_bytes(0_u32, IO::ByteFormat::BigEndian) # 0 objects
        mem.write(Bytes.new(20, 0xFFu8))                  # wrong trailing SHA-1
        mem.rewind

        expect_raises(Git::Pack::FileError, /checksum/) do
          Git::Pack::File.receive(mem, File.join(dir, "bad_checksum.pack"))
        end
      end
    end

    it "raises Pack::FileError on bad magic" do
      mem = IO::Memory.new("JUNK".to_slice)
      with_tmpdir do |dir|
        expect_raises(Git::Pack::FileError, /magic/) do
          Git::Pack::File.receive(mem, File.join(dir, "bad.pack"))
        end
      end
    end

    it "raises Pack::FileError on unsupported version" do
      mem = IO::Memory.new
      mem.write("PACK".to_slice)
      mem.write_bytes(3_u32, IO::ByteFormat::BigEndian)
      mem.write_bytes(0_u32, IO::ByteFormat::BigEndian)
      mem.rewind
      with_tmpdir do |dir|
        expect_raises(Git::Pack::FileError, /version/) do
          Git::Pack::File.receive(mem, File.join(dir, "bad.pack"))
        end
      end
    end

    it "raises Pack::FileError on unexpected EOF in header" do
      mem = IO::Memory.new(Bytes[0x50, 0x41]) # "PA" — truncated
      with_tmpdir do |dir|
        expect_raises(Git::Pack::FileError, /EOF/) do
          Git::Pack::File.receive(mem, File.join(dir, "eof.pack"))
        end
      end
    end
  end
end
