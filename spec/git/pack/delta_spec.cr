require "../../spec_helper"

describe Git::Pack::Delta do
  describe ".apply" do
    it "applies a pure-ADD delta" do
      # Delta: base_size=0, result_size=5, ADD "hello"
      delta = IO::Memory.new
      delta.write_byte(0u8) # base_size varint = 0
      delta.write_byte(5u8) # result_size varint = 5
      delta.write_byte(5u8) # ADD instruction: len = 5 (bit 7 = 0, bits 6:0 = 5)
      delta.write("hello".to_slice)
      delta.rewind

      result = Git::Pack::Delta.apply(Bytes.empty, delta.to_slice)
      String.new(result).should eq("hello")
    end

    it "applies a COPY instruction" do
      base = "hello world".to_slice
      # Delta: base_size=11, result_size=5, COPY offset=0 len=5
      delta = IO::Memory.new
      delta.write_byte(11u8) # base_size = 11
      delta.write_byte(5u8)  # result_size = 5
      # COPY opcode: bit7=1, bit0=1 (offset byte 0 follows), bit4=1 (len byte 0 follows)
      delta.write_byte(0x91u8) # 0b10010001 = COPY with offset_byte1 and len_byte1
      delta.write_byte(0u8)    # offset = 0
      delta.write_byte(5u8)    # len = 5
      delta.rewind

      result = Git::Pack::Delta.apply(base, delta.to_slice)
      String.new(result).should eq("hello")
    end

    it "applies a mix of COPY and ADD" do
      base = "hello".to_slice
      # Result: "hello world" — COPY 5 bytes from offset 0, ADD " world"
      delta = IO::Memory.new
      delta.write_byte(5u8)  # base_size = 5
      delta.write_byte(11u8) # result_size = 11
      # COPY: offset=0, len=5
      delta.write_byte(0x91u8) # COPY with offset_byte0 + len_byte0
      delta.write_byte(0u8)    # offset = 0
      delta.write_byte(5u8)    # len = 5
      # ADD: " world" (6 bytes)
      delta.write_byte(6u8) # ADD len=6
      delta.write(" world".to_slice)
      delta.rewind

      result = Git::Pack::Delta.apply(base, delta.to_slice)
      String.new(result).should eq("hello world")
    end

    it "uses default COPY length of 65536 when len bytes are zero" do
      base = Bytes.new(65536, 0xABu8)
      delta = IO::Memory.new
      # base_size varint for 65536: needs 3 bytes
      delta.write_byte(0x80u8) # 0 | 0x80 (more)
      delta.write_byte(0x80u8) # 0 | 0x80 (more)
      delta.write_byte(0x04u8) # 4 (total: 65536)
      # result_size = 65536 (same)
      delta.write_byte(0x80u8)
      delta.write_byte(0x80u8)
      delta.write_byte(0x04u8)
      # COPY: opcode with NO length bytes set → default len = 65536
      delta.write_byte(0x80u8) # bit7=1 (COPY), no len bits, no offset bits → offset=0, len=default
      delta.rewind

      result = Git::Pack::Delta.apply(base, delta.to_slice)
      result.size.should eq(65536)
      result.should eq(base)
    end

    it "raises on base size mismatch" do
      base = "hi".to_slice
      delta = IO::Memory.new
      delta.write_byte(5u8) # claims base is 5 bytes
      delta.write_byte(0u8)
      delta.rewind

      expect_raises(Git::Pack::FileError, /mismatch/) do
        Git::Pack::Delta.apply(base, delta.to_slice)
      end
    end

    it "raises when the size varint extends beyond the delta buffer" do
      # Regression: an all-0x80 byte stream has the continuation bit always set,
      # causing the varint reader to run off the end of the slice.
      delta = Bytes.new(10, 0x80u8)
      expect_raises(Git::Pack::FileError) do
        Git::Pack::Delta.apply(Bytes.empty, delta)
      end
    end

    it "raises when the reconstructed result size does not match the declared size" do
      # Regression: previously result_size was only used as IO::Memory capacity;
      # a short or long result produced a silently wrong SHA-1 in the pack index.
      delta = IO::Memory.new
      delta.write_byte(0u8)  # base_size = 0
      delta.write_byte(10u8) # result_size = 10, but we only ADD 3 bytes
      delta.write_byte(3u8)  # ADD len=3
      delta.write("abc".to_slice)
      delta.rewind

      expect_raises(Git::Pack::FileError, /result size mismatch/) do
        Git::Pack::Delta.apply(Bytes.empty, delta.to_slice)
      end
    end

    it "raises on ADD with zero length" do
      base = Bytes.empty
      delta = IO::Memory.new
      delta.write_byte(0u8) # base_size = 0
      delta.write_byte(0u8) # result_size = 0
      delta.write_byte(0u8) # ADD with len=0 (invalid)
      delta.rewind

      expect_raises(Git::Pack::FileError, /zero length/) do
        Git::Pack::Delta.apply(base, delta.to_slice)
      end
    end
  end

  describe ".git_sha1" do
    it "produces the correct git blob SHA1" do
      # Known SHA1: git hash-object for empty string = e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
      sha = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, Bytes.empty)
      sha.to_hex.should eq("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    end

    it "produces the correct git blob SHA1 for 'hello\\n'" do
      # echo "hello" | git hash-object --stdin => ce013625030ba8dba906f756967f9e9ca394464a
      data = "hello\n".to_slice
      sha = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data)
      sha.to_hex.should eq("ce013625030ba8dba906f756967f9e9ca394464a")
    end
  end
end
