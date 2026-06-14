require "../../spec_helper"

describe Git::Pack::CRC32 do
  it "returns 0x00000000 for empty input" do
    Git::Pack::CRC32.digest(Bytes[]).should eq(0x00000000_u32)
  end

  it "matches the standard CRC32 test vector for '123456789'" do
    Git::Pack::CRC32.digest("123456789".to_slice).should eq(0xCBF43926_u32)
  end

  it "update is associative: digest(a+b) == update(digest_partial(a), b)" do
    a = "hello".to_slice
    b = " world".to_slice
    full = Git::Pack::CRC32.digest((String.new(a) + String.new(b)).to_slice)
    partial = Git::Pack::CRC32.update(0xFFFFFFFF_u32, a) # raw, not finalized
    # Full digest via two-step update
    two_step = Git::Pack::CRC32.update(partial, b) ^ 0xFFFFFFFF_u32
    full.should eq(two_step)
  end
end
