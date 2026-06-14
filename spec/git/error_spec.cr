require "../spec_helper"

describe Git::Error do
  it "is a subclass of Exception" do
    Git::Error.new("boom").should be_a(Exception)
  end

  it "preserves the message" do
    Git::Error.new("test message").message.should eq("test message")
  end

  it "ProtocolError is a subclass of Error" do
    Git::ProtocolError.new("x").should be_a(Git::Error)
  end

  it "TransportError is a subclass of Error" do
    Git::TransportError.new("x").should be_a(Git::Error)
  end

  it "Pack::FileError is a subclass of Error" do
    Git::Pack::FileError.new("x").should be_a(Git::Error)
  end

  it "RepositoryError is a subclass of Error" do
    Git::RepositoryError.new("x").should be_a(Git::Error)
  end

  it "AuthenticationError is a subclass of TransportError" do
    Git::AuthenticationError.new("x").should be_a(Git::TransportError)
  end

  it "AuthenticationError is a subclass of Error" do
    Git::AuthenticationError.new("x").should be_a(Git::Error)
  end
end
