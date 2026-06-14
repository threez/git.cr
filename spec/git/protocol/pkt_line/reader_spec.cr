require "../../../spec_helper"

describe Git::Protocol::PktLine::Reader do
  it "decodes a single data packet" do
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_data("hello\n")
    mem.rewind
    type, data = Git::Protocol::PktLine::Reader.new(mem).read_packet
    type.should eq(Git::Protocol::PktLine::Type::Data)
    String.new(data.not_nil!).should eq("hello\n") # ameba:disable Lint/NotNil
  end

  it "round-trips multiple packets and a flush via read_lines_until_flush" do
    mem = IO::Memory.new
    w = Git::Protocol::PktLine::Writer.new(mem)
    w.write_data("line1\n")
    w.write_data("line2\n")
    w.write_flush
    mem.rewind
    Git::Protocol::PktLine::Reader.new(mem).read_lines_until_flush.should eq(["line1", "line2"])
  end

  it "decodes a flush packet as Flush type with nil data" do
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_flush
    mem.rewind
    type, data = Git::Protocol::PktLine::Reader.new(mem).read_packet
    type.should eq(Git::Protocol::PktLine::Type::Flush)
    data.should be_nil
  end

  it "round-trips binary data" do
    payload = Bytes[1, 2, 3, 0, 255]
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_data(payload)
    mem.rewind
    _, data = Git::Protocol::PktLine::Reader.new(mem).read_packet
    data.not_nil!.should eq(payload) # ameba:disable Lint/NotNil
  end

  it "decodes a delim packet" do
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_delim
    mem.rewind
    type, _ = Git::Protocol::PktLine::Reader.new(mem).read_packet
    type.should eq(Git::Protocol::PktLine::Type::Delim)
  end

  it "raises ProtocolError on truncated header" do
    mem = IO::Memory.new(Bytes[0x30, 0x30]) # only 2 bytes, not 4
    expect_raises(Git::ProtocolError) do
      Git::Protocol::PktLine::Reader.new(mem).read_packet
    end
  end

  it "raises ProtocolError on invalid hex in header" do
    mem = IO::Memory.new("gggg".to_slice)
    expect_raises(Git::ProtocolError) do
      Git::Protocol::PktLine::Reader.new(mem).read_packet
    end
  end

  it "raises ProtocolError when packet body is truncated" do
    mem = IO::Memory.new
    Git::Protocol::PktLine::Writer.new(mem).write_data("hello\n")
    mem.rewind
    truncated = IO::Memory.new(mem.to_slice[0, 4])
    expect_raises(Git::ProtocolError) do
      Git::Protocol::PktLine::Reader.new(truncated).read_packet
    end
  end
end
