require "../../spec_helper"
require "compress/zlib"

describe Git::Pack::Inflate do
  it "decompresses zlib-compressed data back to the original" do
    original = "hello, git inflate test\n".to_slice
    compressed_buf = IO::Memory.new
    Compress::Zlib::Writer.open(compressed_buf, &.write(original))
    compressed = compressed_buf.to_slice

    pack = compressed # treat compressed bytes as the pack slice starting at offset 0
    result, consumed = Git::Pack::Inflate.at(pack, 0, original.size)

    result.should eq(original)
    consumed.should eq(compressed.size)
  end

  it "raises Pack::FileError when the decompressed size does not match expected_size" do
    # Regression: previously a short inflate returned a zero-padded buffer and
    # produced a bogus SHA-1 instead of raising.
    data = "hello\n".to_slice
    buf = IO::Memory.new
    Compress::Zlib::Writer.open(buf, &.write(data))
    compressed = buf.to_slice

    expect_raises(Git::Pack::FileError, /size mismatch/) do
      Git::Pack::Inflate.at(compressed, 0, data.size + 1) # expected_size is one byte too large
    end
  end

  it "consumed length equals the number of compressed bytes read" do
    data = Bytes.new(256, &.to_u8)
    buf = IO::Memory.new
    Compress::Zlib::Writer.open(buf, &.write(data))
    compressed = buf.to_slice

    _, consumed = Git::Pack::Inflate.at(compressed, 0, data.size)
    consumed.should eq(compressed.size)
  end
end
