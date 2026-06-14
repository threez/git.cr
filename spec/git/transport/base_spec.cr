require "../../spec_helper"

describe Git::Transport do
  describe ".for" do
    it "returns Transport::Http for https://" do
      url = Git.remote("https://github.com/example/repo.git")
      Git::Transport.for(url).should be_a(Git::Transport::HTTP)
    end

    it "returns Transport::SSH for ssh://" do
      url = Git.remote("git@github.com:example/repo.git")
      Git::Transport.for(url).should be_a(Git::Transport::SSH)
    end

    it "returns Transport::File for file://" do
      url = Git.remote("file:///tmp/repo.git")
      Git::Transport.for(url).should be_a(Git::Transport::File)
    end
  end
end
