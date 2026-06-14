require "../../spec_helper"
require "http/server"
require "base64"

# Starts an in-process HTTP server that responds with the given status and headers,
# yields the port to the block, then shuts the server down.
private def with_http_server(status : Int32, content_type : String, body : String = "", &block : Int32 ->) : Nil
  server = HTTP::Server.new do |ctx|
    ctx.response.status_code = status
    ctx.response.headers["Content-Type"] = content_type
    ctx.response.print(body)
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn server.listen
  begin
    block.call(address.port)
  ensure
    server.close
  end
end

describe Git::Transport::HTTP do
  describe "#info_refs_body" do
    it "raises TransportError on a non-200 HTTP status" do
      with_http_server(404, "text/plain", "not found") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        expect_raises(Git::TransportError, /404/) do
          transport.info_refs_body
        end
      end
    end

    it "raises TransportError when Content-Type is unexpected" do
      with_http_server(200, "text/html", "wrong type") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        expect_raises(Git::TransportError, /Content-Type/) do
          transport.info_refs_body
        end
      end
    end
  end

  describe "#fetch_pack" do
    it "raises TransportError on a non-200 HTTP status" do
      with_http_server(500, "text/plain", "server error") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        expect_raises(Git::TransportError, /500/) do
          transport.fetch_pack(Bytes.empty) { }
        end
      end
    end
  end

  describe "#request" do
    it "delegates to fetch_pack and yields the response IO" do
      with_http_server(200, "application/x-git-upload-pack-result", "PACKDATA") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        received = ""
        transport.request(Bytes.empty) { |io| received = io.gets_to_end }
        received.should eq("PACKDATA")
      end
    end
  end

  describe "Git-Protocol header" do
    it "sends Git-Protocol: version=2 on info_refs_body" do
      captured = Channel(String?).new(1)
      server = HTTP::Server.new do |ctx|
        captured.send(ctx.request.headers["Git-Protocol"]?) unless captured.closed?
        ctx.response.status_code = 200
        ctx.response.headers["Content-Type"] = "application/x-git-upload-pack-advertisement"
        ctx.response.print("")
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn server.listen
      begin
        url = Git.remote("http://127.0.0.1:#{address.port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        transport.info_refs_body rescue Git::TransportError
        captured.receive?.should eq("version=2")
      ensure
        server.close
      end
    end

    it "sends Git-Protocol: version=2 on fetch_pack" do
      captured = Channel(String?).new(1)
      server = HTTP::Server.new do |ctx|
        captured.send(ctx.request.headers["Git-Protocol"]?) unless captured.closed?
        ctx.response.status_code = 200
        ctx.response.headers["Content-Type"] = "application/x-git-upload-pack-result"
        ctx.response.print("")
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn server.listen
      begin
        url = Git.remote("http://127.0.0.1:#{address.port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        transport.fetch_pack(Bytes.empty) { } rescue Git::TransportError
        captured.receive?.should eq("version=2")
      ensure
        server.close
      end
    end
  end

  describe "authentication" do
    it "sends Authorization header with Bearer token on info_refs_body" do
      captured = Channel(String?).new(1)
      server = HTTP::Server.new do |ctx|
        captured.send(ctx.request.headers["Authorization"]?) unless captured.closed?
        ctx.response.status_code = 200
        ctx.response.headers["Content-Type"] = "application/x-git-upload-pack-advertisement"
        ctx.response.print("")
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn server.listen
      begin
        url = Git.remote("http://127.0.0.1:#{address.port}/repo.git")
        transport = Git::Transport::HTTP.new(url, Git.bearer("test-token"))
        transport.info_refs_body rescue Git::TransportError
        captured.receive?.should eq("Bearer test-token")
      ensure
        server.close
      end
    end

    it "sends Authorization header with Basic credentials on info_refs_body" do
      captured = Channel(String?).new(1)
      server = HTTP::Server.new do |ctx|
        captured.send(ctx.request.headers["Authorization"]?) unless captured.closed?
        ctx.response.status_code = 200
        ctx.response.headers["Content-Type"] = "application/x-git-upload-pack-advertisement"
        ctx.response.print("")
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn server.listen
      begin
        url = Git.remote("http://127.0.0.1:#{address.port}/repo.git")
        transport = Git::Transport::HTTP.new(url, Git.basic("user", "secret"))
        transport.info_refs_body rescue Git::TransportError
        captured.receive?.should eq("Basic #{Base64.strict_encode("user:secret")}")
      ensure
        server.close
      end
    end

    it "sends Authorization header on fetch_pack" do
      captured = Channel(String?).new(1)
      server = HTTP::Server.new do |ctx|
        captured.send(ctx.request.headers["Authorization"]?) unless captured.closed?
        ctx.response.status_code = 200
        ctx.response.headers["Content-Type"] = "application/x-git-upload-pack-result"
        ctx.response.print("")
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn server.listen
      begin
        url = Git.remote("http://127.0.0.1:#{address.port}/repo.git")
        transport = Git::Transport::HTTP.new(url, Git.bearer("post-token"))
        transport.fetch_pack(Bytes.empty) { } rescue Git::TransportError
        captured.receive?.should eq("Bearer post-token")
      ensure
        server.close
      end
    end

    it "raises AuthenticationError when server returns 401 on info_refs_body (no credentials)" do
      with_http_server(401, "text/plain", "Unauthorized") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        expect_raises(Git::AuthenticationError, /401/) do
          transport.info_refs_body
        end
      end
    end

    it "raises AuthenticationError when server returns 401 on fetch_pack (no credentials)" do
      with_http_server(401, "text/plain", "Unauthorized") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        expect_raises(Git::AuthenticationError) do
          transport.fetch_pack(Bytes.empty) { }
        end
      end
    end

    it "raises AuthenticationError even when credentials are provided but server returns 401 (wrong credentials)" do
      with_http_server(401, "text/plain", "Unauthorized") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url, Git.bearer("wrong"))
        expect_raises(Git::AuthenticationError) do
          transport.info_refs_body
        end
      end
    end

    it "AuthenticationError is caught by rescue TransportError" do
      with_http_server(401, "text/plain", "Unauthorized") do |port|
        url = Git.remote("http://127.0.0.1:#{port}/repo.git")
        transport = Git::Transport::HTTP.new(url)
        rescued = false
        begin
          transport.info_refs_body
        rescue Git::TransportError
          rescued = true
        end
        rescued.should be_true
      end
    end
  end
end
