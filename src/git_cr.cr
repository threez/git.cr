require "option_parser"
require "./git"

private def build_credentials(user : String?, password : String?, token : String?) : Git::Transport::Credentials?
  if token
    Git.bearer(token)
  elsif user && password
    Git.basic(user, password)
  end
end

private def on_progress : Git::Protocol::ProgressCallback
  ->(msg : Git::Protocol::ProgressMessage) {
    if msg.done?
      STDERR.puts "\r#{msg.raw}"
    else
      STDERR.print "\r#{msg.raw}"
    end
  }
end

private def die(message : String) : NoReturn
  STDERR.puts "error: #{message}"
  exit 1
end

GENERAL_HELP = <<-HELP
  Usage: git-cr <command> [options]

  Commands:
    clone  <url> <dir>  Clone a remote repository into a new directory
    pull   <dir>        Fetch and fast-forward the working tree
    sync   <dir>        Fetch and fast-forward, or hard-reset if diverged
    reset  <dir>        Fetch and hard-reset to remote HEAD unconditionally

  Run `git-cr <command> --help` for per-command options.
  HELP

command = ARGV.shift? || ""

case command
when "", "-h", "--help"
  puts GENERAL_HELP
  exit 0
when "clone"
  url = nil
  dir = nil
  branch = "HEAD"
  lfs = true
  submodules = true
  depth = nil
  git_dir_path = nil
  user = nil
  password = nil
  token = nil

  OptionParser.parse(ARGV) do |parser|
    parser.banner = "Usage: git-cr clone <url> <dir> [options]"
    parser.on("-b BRANCH", "--branch BRANCH", "Branch to clone (default: HEAD)") { |v| branch = v }
    parser.on("--depth N", "Create a shallow clone with N commits") { |v| depth = v.to_i }
    parser.on("--git-dir PATH", "Store git metadata in a separate directory") { |v| git_dir_path = v }
    parser.on("--no-lfs", "Skip LFS objects") { lfs = false }
    parser.on("--no-submodules", "Skip submodule initialisation") { submodules = false }
    parser.on("--user USER", "HTTP basic-auth username") { |v| user = v }
    parser.on("--password PASS", "HTTP basic-auth password") { |v| password = v }
    parser.on("--token TOKEN", "HTTP bearer token") { |v| token = v }
    parser.on("-h", "--help", "Show this help") { puts parser; exit 0 }
    parser.unknown_args { |args| url = args[0]?; dir = args[1]? }
  end

  url_val = url || die "missing <url>"
  dir_val = dir || die "missing <dir>"
  git_dir = git_dir_path ? Git.fs(git_dir_path) : nil
  credentials = build_credentials(user, password, token)

  begin
    Git::Client.clone(
      url_val, Git.safe_fs(dir_val),
      branch: branch, lfs: lfs, submodules: submodules,
      depth: depth, git_dir: git_dir,
      credentials: credentials, on_progress: on_progress
    )
  rescue ex : Git::Error
    die ex.message || ex.class.name
  end
when "pull", "sync", "reset"
  dir = nil
  branch = "HEAD"
  lfs = true
  submodules = true
  user = nil
  password = nil
  token = nil

  OptionParser.parse(ARGV) do |parser|
    parser.banner = "Usage: git-cr #{command} <dir> [options]"
    parser.on("-b BRANCH", "--branch BRANCH", "Branch to track (default: HEAD)") { |v| branch = v }
    parser.on("--no-lfs", "Skip LFS objects") { lfs = false }
    parser.on("--no-submodules", "Skip submodule updates") { submodules = false }
    parser.on("--user USER", "HTTP basic-auth username") { |v| user = v }
    parser.on("--password PASS", "HTTP basic-auth password") { |v| password = v }
    parser.on("--token TOKEN", "HTTP bearer token") { |v| token = v }
    parser.on("-h", "--help", "Show this help") { puts parser; exit 0 }
    parser.unknown_args { |args| dir = args[0]? }
  end

  dir_val = dir || die "missing <dir>"
  fs = Git.safe_fs(dir_val)
  credentials = build_credentials(user, password, token)

  begin
    case command
    when "pull"
      Git::Client.pull(fs, branch: branch, lfs: lfs, submodules: submodules,
        credentials: credentials, on_progress: on_progress)
    when "sync"
      Git::Client.sync(fs, branch: branch, lfs: lfs, submodules: submodules,
        credentials: credentials, on_progress: on_progress)
    when "reset"
      Git::Client.reset(fs, branch: branch, lfs: lfs, submodules: submodules,
        credentials: credentials, on_progress: on_progress)
    end
  rescue ex : Git::Error
    die ex.message || ex.class.name
  end
else
  die "unknown command '#{command}' — try: clone, pull, sync, reset"
end
