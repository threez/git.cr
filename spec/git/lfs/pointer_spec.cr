require "../../spec_helper"

VALID_OID = "a" * 64

describe Git::LFS::Pointer do
  describe ".parse?" do
    it "parses a valid LFS pointer" do
      data = "version https://git-lfs.github.com/spec/v1\noid sha256:#{VALID_OID}\nsize 1234\n"
      pointer = Git::LFS::Pointer.parse?(data.to_slice)
      pointer.should_not be_nil
      pointer.try(&.oid).should eq(VALID_OID)
      pointer.try(&.size).should eq(1234_i64)
    end

    it "returns nil for blobs larger than 200 bytes" do
      data = "x" * 201
      Git::LFS::Pointer.parse?(data.to_slice).should be_nil
    end

    it "returns nil when the LFS header is absent" do
      data = "oid sha256:#{VALID_OID}\nsize 1234\n"
      Git::LFS::Pointer.parse?(data.to_slice).should be_nil
    end

    it "returns nil when the oid line is absent" do
      data = "version https://git-lfs.github.com/spec/v1\nsize 1234\n"
      Git::LFS::Pointer.parse?(data.to_slice).should be_nil
    end

    it "returns nil when the size line is absent" do
      data = "version https://git-lfs.github.com/spec/v1\noid sha256:#{VALID_OID}\n"
      Git::LFS::Pointer.parse?(data.to_slice).should be_nil
    end

    it "returns nil for regular source code" do
      data = "def hello\n  puts \"world\"\nend\n"
      Git::LFS::Pointer.parse?(data.to_slice).should be_nil
    end

    it "returns nil for empty bytes" do
      Git::LFS::Pointer.parse?(Bytes.empty).should be_nil
    end
  end
end
