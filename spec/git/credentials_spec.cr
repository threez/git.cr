require "../spec_helper"
require "base64"

describe Git::Transport::Credentials do
  describe ".bearer" do
    it "produces 'Bearer <token>'" do
      creds = Git.bearer("ghp_abc123")
      creds.to_authorization_header.should eq("Bearer ghp_abc123")
    end

    it "preserves the token verbatim" do
      token = "eyJhbGciOiJSUzI1NiJ9.test"
      Git.bearer(token).to_authorization_header.should eq("Bearer #{token}")
    end
  end

  describe ".basic" do
    it "produces 'Basic <base64(user:password)>'" do
      Git.basic("user", "secret").to_authorization_header.should eq(
        "Basic #{Base64.strict_encode("user:secret")}"
      )
    end

    it "handles an empty password (token-as-username pattern)" do
      creds = Git.basic("ghp_abc123", "")
      creds.to_authorization_header.should start_with("Basic ")
      decoded = Base64.decode_string(creds.to_authorization_header[6..])
      decoded.should eq("ghp_abc123:")
    end

    it "handles colons in the password (only first colon separates user from password)" do
      creds = Git.basic("user", "pass:with:colons")
      decoded = Base64.decode_string(creds.to_authorization_header[6..])
      decoded.should eq("user:pass:with:colons")
    end

    it "uses strict Base64 encoding (no newlines)" do
      long_user = "a" * 50
      long_pass = "b" * 50
      header = Git.basic(long_user, long_pass).to_authorization_header
      header.should_not contain("\n")
    end
  end

  describe "AuthenticationError hierarchy" do
    it "is a subclass of TransportError" do
      Git::AuthenticationError.new("x").should be_a(Git::TransportError)
    end

    it "is a subclass of Git::Error" do
      Git::AuthenticationError.new("x").should be_a(Git::Error)
    end

    it "is an Exception" do
      Git::AuthenticationError.new("x").should be_a(Exception)
    end
  end
end
