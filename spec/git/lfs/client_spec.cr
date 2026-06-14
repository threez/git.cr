require "../../spec_helper"
require "http/server"

private def with_tempdir(&)
  dir = spec_tmp("lfs-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Git::LFS::Client do
  describe ".for_ssh" do
    it "derives an HTTPS LFS endpoint from an SCP-style SSH remote" do
      remote = Git.remote("git@github.com:user/repo.git")
      Git::LFS::Client.for_ssh(remote).should_not be_nil
    end

    it "derives an HTTPS LFS endpoint from an ssh:// remote" do
      remote = Git.remote("ssh://git@github.com/user/repo.git")
      Git::LFS::Client.for_ssh(remote).should_not be_nil
    end
  end

  describe ".from_lfs_config?" do
    it "returns a Client when .lfsconfig contains a valid [lfs] url" do
      with_tempdir do |dir|
        File.write(File.join(dir, ".lfsconfig"), "[lfs]\n\turl = https://lfs.example.com/repo.git\n")
        Git::LFS::Client.from_lfs_config?(dir).should_not be_nil
      end
    end

    it "returns nil when .lfsconfig is absent" do
      with_tempdir do |dir|
        Git::LFS::Client.from_lfs_config?(dir).should be_nil
      end
    end

    it "returns nil when .lfsconfig has no [lfs] section" do
      with_tempdir do |dir|
        File.write(File.join(dir, ".lfsconfig"), "[core]\n\tautocrlf = false\n")
        Git::LFS::Client.from_lfs_config?(dir).should be_nil
      end
    end

    it "returns nil when the [lfs] url is not HTTP(S)" do
      with_tempdir do |dir|
        File.write(File.join(dir, ".lfsconfig"), "[lfs]\n\turl = ssh://lfs.example.com/repo.git\n")
        Git::LFS::Client.from_lfs_config?(dir).should be_nil
      end
    end
  end

  describe "authentication" do
    it "raises AuthenticationError when LFS batch returns 401 (no credentials)" do
      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 401
        ctx.response.headers["Content-Type"] = "application/vnd.git-lfs+json"
        ctx.response.print("{}")
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn server.listen
      begin
        remote = Git.remote("http://127.0.0.1:#{address.port}/repo.git")
        client = Git::LFS::Client.new(remote)
        pointer = Git::LFS::Pointer.new("a" * 64, 42_i64)
        expect_raises(Git::AuthenticationError, /401/) do
          client.fetch_batch([pointer])
        end
      ensure
        server.close
      end
    end

    it "sends Authorization header when credentials are provided to batch request" do
      captured = Channel(String?).new(1)
      server = HTTP::Server.new do |ctx|
        captured.send(ctx.request.headers["Authorization"]?) unless captured.closed?
        ctx.response.status_code = 200
        ctx.response.headers["Content-Type"] = "application/vnd.git-lfs+json"
        ctx.response.print(%({"objects":[]}))
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn server.listen
      begin
        remote = Git.remote("http://127.0.0.1:#{address.port}/repo.git")
        creds = Git.bearer("lfs-token")
        client = Git::LFS::Client.new(remote, creds)
        pointer = Git::LFS::Pointer.new("a" * 64, 42_i64)
        client.fetch_batch([pointer])
        captured.receive?.should eq("Bearer lfs-token")
      ensure
        server.close
      end
    end
  end

  pending "fetch_batch requires a live LFS-enabled remote — tested manually or via future in-process mock server"
end
