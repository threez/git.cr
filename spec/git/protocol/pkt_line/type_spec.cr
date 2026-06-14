require "../../../spec_helper"

describe Git::Protocol::PktLine::Type do
  it "has distinct values for all packet kinds" do
    [Git::Protocol::PktLine::Type::Data,
     Git::Protocol::PktLine::Type::Flush,
     Git::Protocol::PktLine::Type::Delim,
     Git::Protocol::PktLine::Type::ResponseEnd].uniq.size.should eq(4)
  end

  it "Data is the zero-value / first member" do
    Git::Protocol::PktLine::Type::Data.value.should eq(0)
  end
end
