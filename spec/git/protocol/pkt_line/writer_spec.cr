require "../../../spec_helper"

describe Git::Protocol::PktLine::Writer do
  it "encodes the correct 4-hex-char length prefix" do
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_data("hello\n")
    mem.rewind
    # "hello\n" is 6 bytes + 4 header = 10 = 0x000a
    mem.gets(4).should eq("000a")
  end

  it "write_flush writes 0000" do
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_flush
    String.new(mem.to_slice).should eq("0000")
  end

  it "write_delim writes 0001" do
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_delim
    String.new(mem.to_slice).should eq("0001")
  end

  it "raises ProtocolError when writing an oversized packet" do
    mem = IO::Memory.new
    big = Bytes.new(Git::Protocol::PktLine::MAX_DATA_SIZE + 1)
    expect_raises(Git::ProtocolError) do
      Git::Protocol::PktLine::Writer.new(mem).write_data(big)
    end
  end
end
