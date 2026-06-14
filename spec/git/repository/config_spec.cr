require "../../spec_helper"

describe Git::Repository::Config do
  config_text = <<-INI
    [core]
    \trepositoryformatversion = 0
    \tfilemode = true
    \tbare = false
    [remote "origin"]
    \turl = https://github.com/foo/bar.git
    \tfetch = +refs/heads/*:refs/remotes/origin/*
    INI

  describe ".parse" do
    it "returns the remote URL" do
      cfg = Git::Repository::Config.parse(config_text)
      cfg.remote_url("origin").should eq("https://github.com/foo/bar.git")
    end

    it "defaults to origin" do
      cfg = Git::Repository::Config.parse(config_text)
      cfg.remote_url.should eq("https://github.com/foo/bar.git")
    end

    it "raises for unknown remote" do
      cfg = Git::Repository::Config.parse(config_text)
      expect_raises(Git::RepositoryError, /upstream/) do
        cfg.remote_url("upstream")
      end
    end

    it "parses SSH remote URL" do
      text = "[remote \"origin\"]\n\turl = git@github.com:foo/bar.git\n"
      cfg = Git::Repository::Config.parse(text)
      cfg.remote_url.should eq("git@github.com:foo/bar.git")
    end
  end
end
