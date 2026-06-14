module Git
  # Represents an on-disk `.git/` directory and provides low-level helpers for reading
  # and writing refs, HEAD, config, and pack storage. Does not touch the working tree —
  # that is `Checkout`'s responsibility.
  class Repository
    HEAD_FILE       = "HEAD"
    FETCH_HEAD_FILE = "FETCH_HEAD"
    ORIG_HEAD_FILE  = "ORIG_HEAD"
    PACKED_REFS     = "packed-refs"
    SHALLOW_FILE    = "shallow"
    GIT_DIR         = ".git"
    GITDIR_PREFIX   = "gitdir: "
    SYMREF_PREFIX   = "ref: refs/heads/"

    # Filesystem anchored at the `.git/` directory (or the separate git dir when
    # `--separate-git-dir` was used). Use `git_dir.root` to get the path as a `String`.
    getter git_dir : FileSystem

    def initialize(@git_dir : FileSystem)
      @packfile_path = nil.as(String?)
    end

    # Initializes a new git directory for *work_dir*. Raises RepositoryError if
    # `.git` already exists inside *work_dir*.
    #
    # ### Parameters
    #
    # *work_dir* — Filesystem anchored at the working tree root. The root is created if it
    # does not exist.
    #
    # *git_dir* — When set, stores git metadata at this separate path (equivalent
    # to `git clone --separate-git-dir`). A gitfile named `.git` is written inside
    # *work_dir* containing `gitdir: <absolute_path>`. When `nil` (the default),
    # the git directory is created at `work_dir.root/.git`.
    def self.init(work_dir : FileSystem, git_dir : FileSystem? = nil) : Repository
      if separate = git_dir
        dot_git = work_dir.join(GIT_DIR)
        if work_dir.exists?(dot_git)
          raise RepositoryError.new("Repository already exists at #{dot_git}")
        end
        if separate.directory?(separate.root) && !separate.dir_empty?(separate.root)
          raise RepositoryError.new("git_dir already exists and is not empty: #{separate.root}")
        end
        work_dir.mkdir_p(work_dir.root)
        separate.mkdir_p(separate.join("objects", "pack"))
        separate.mkdir_p(separate.join("refs", "heads"))
        separate.mkdir_p(separate.join("refs", "tags"))
        separate.mkdir_p(separate.join("refs", "remotes"))
        work_dir.write(dot_git, "#{GITDIR_PREFIX}#{separate.root}\n")
        new(separate)
      else
        git_dir_fs = work_dir.chroot(GIT_DIR)
        if work_dir.directory?(git_dir_fs.root)
          raise RepositoryError.new("Repository already exists at #{git_dir_fs.root}")
        end
        git_dir_fs.mkdir_p(git_dir_fs.join("objects", "pack"))
        git_dir_fs.mkdir_p(git_dir_fs.join("refs", "heads"))
        git_dir_fs.mkdir_p(git_dir_fs.join("refs", "tags"))
        git_dir_fs.mkdir_p(git_dir_fs.join("refs", "remotes"))
        new(git_dir_fs)
      end
    end

    # Opens the git repository whose working tree is *work_dir*.
    # Handles both the normal case (`.git/` is a directory) and the gitfile case
    # (`.git` is a plain file containing `gitdir: <path>`).
    # Raises `RepositoryError` if neither form is present.
    def self.open(work_dir : FileSystem) : Repository
      dot_git = work_dir.join(GIT_DIR)
      if work_dir.directory?(dot_git)
        new(work_dir.chroot(GIT_DIR))
      elsif work_dir.file?(dot_git)
        new(resolve_gitfile(dot_git, work_dir))
      else
        raise RepositoryError.new("Not a git repository: #{work_dir.root}")
      end
    end

    private def self.resolve_gitfile(gitfile_path : String, work_dir : FileSystem) : FileSystem::Local
      content = work_dir.read(gitfile_path).strip
      prefix = GITDIR_PREFIX
      unless content.starts_with?(prefix)
        raise RepositoryError.new("Malformed gitfile at #{gitfile_path}: expected 'gitdir: <path>'")
      end
      raw_path = content[prefix.size..]
      if raw_path.empty?
        raise RepositoryError.new("Malformed gitfile at #{gitfile_path}: empty path after 'gitdir: '")
      end
      resolved = File.expand_path(raw_path, work_dir.root)
      unless File.directory?(resolved)
        raise RepositoryError.new("gitdir '#{resolved}' from gitfile does not exist")
      end
      FileSystem::Local.new(resolved)
    end

    # Returns the path to the `objects/pack/` directory inside this repository.
    def objects_pack_dir : String
      @git_dir.join("objects", "pack")
    end

    # Returns the path to `.git/objects/info/commit-graph`.
    def commit_graph_path : String
      @git_dir.join("objects", "info", "commit-graph")
    end

    # Returns true when a commit-graph file is present.
    def commit_graph_exists? : Bool
      @git_dir.file?(commit_graph_path)
    end

    # Returns the name of the current branch (e.g. `"main"`).
    # Raises `RepositoryError` if the repository is in detached HEAD state.
    def current_branch : String
      head = @git_dir.read(@git_dir.join(HEAD_FILE)).strip
      raise RepositoryError.new("Repository is in detached HEAD state") unless head.starts_with?(SYMREF_PREFIX)
      head[SYMREF_PREFIX.size..]
    end

    # Returns the tip commit `Object::Id` for *branch*.
    # Checks loose refs first (`refs/heads/<branch>`), then falls back to `packed-refs`.
    # Raises `RepositoryError` if the branch does not exist.
    def branch_tip(branch : String) : Object::Id
      ref_path = @git_dir.join("refs", "heads", branch)
      return Git.oid(@git_dir.read(ref_path).strip) if @git_dir.exists?(ref_path)

      packed = @git_dir.join(PACKED_REFS)
      if @git_dir.exists?(packed)
        target = "#{Ref::HEADS_PREFIX}#{branch}"
        @git_dir.read_lines(packed).each do |line|
          next if line.starts_with?('#') || line.starts_with?('^')
          parts = line.strip.split(' ', 2)
          return Git.oid(parts[0]) if parts.size == 2 && parts[1] == target
        end
      end

      raise RepositoryError.new("Branch #{branch.inspect} not found")
    end

    # Writes *oid* to `refs/heads/<branch>`, creating or overwriting the ref.
    def write_branch(branch : String, oid : Object::Id) : Nil
      path = @git_dir.join("refs", "heads", branch)
      @git_dir.mkdir_p(File.dirname(path))
      LockFile.write(path, @git_dir, &.print(oid.to_hex + "\n"))
    end

    # Returns a fresh random packfile path inside `objects/pack/`. Unlike `packfile_path`,
    # this generates a new name on every call and does not cache the result.
    def new_packfile_path : String
      @git_dir.join("objects", "pack", "pack-#{Random::Secure.hex(20)}.pack")
    end

    # Writes `HEAD` as a symbolic ref pointing to *branch*.
    def write_head(branch : String) : Nil
      LockFile.write(@git_dir.join(HEAD_FILE), @git_dir) { |io| io.print("#{SYMREF_PREFIX}#{branch}\n") }
    end

    # Writes `refs/remotes/<remote>/<branch>` for every `refs/heads/*` ref in *refs*.
    def write_tracking_refs(remote : String, refs : Array(Ref)) : Nil
      refs.each do |ref|
        if branch = ref.branch_name
          write_tracking_ref(remote, branch, ref.oid)
        end
      end
    end

    # Writes (or overwrites) the loose remote-tracking ref `refs/remotes/<remote>/<branch>`.
    def write_tracking_ref(remote : String, branch : String, oid : Object::Id) : Nil
      path = @git_dir.join("refs", "remotes", remote, branch)
      @git_dir.mkdir_p(File.dirname(path))
      LockFile.write(path, @git_dir, &.print(oid.to_hex + "\n"))
    end

    # Reads a remote-tracking ref. Checks the loose file first, then `packed-refs`.
    # Returns nil if the ref does not exist.
    def tracking_ref_tip(remote : String, branch : String) : Object::Id?
      loose = @git_dir.join("refs", "remotes", remote, branch)
      return Git.oid(@git_dir.read(loose).strip) if @git_dir.exists?(loose)

      packed = @git_dir.join(PACKED_REFS)
      if @git_dir.exists?(packed)
        target = "#{Ref::REMOTES_PREFIX}#{remote}/#{branch}"
        @git_dir.read_lines(packed).each do |line|
          next if line.starts_with?('#') || line.starts_with?('^')
          parts = line.strip.split(' ', 2)
          return Git.oid(parts[0]) if parts.size == 2 && parts[1] == target
        end
      end

      nil
    end

    # Writes `.git/FETCH_HEAD` with a single entry for the fetched *branch* at *oid*.
    def write_fetch_head(oid : Object::Id, branch : String, url : String) : Nil
      LockFile.write(@git_dir.join(FETCH_HEAD_FILE), @git_dir) do |io|
        io.print("#{oid.to_hex}\t\tbranch '#{branch}' of '#{url}'\n")
      end
    end

    # Writes `.git/ORIG_HEAD` to record the pre-operation tip.
    def write_orig_head(oid : Object::Id) : Nil
      LockFile.write(@git_dir.join(ORIG_HEAD_FILE), @git_dir) { |io| io.print(oid.to_hex + "\n") }
    end

    # Reads `.git/ORIG_HEAD`. Returns nil when the file does not exist.
    def read_orig_head : Object::Id?
      path = @git_dir.join(ORIG_HEAD_FILE)
      @git_dir.exists?(path) ? Git.oid(@git_dir.read(path).strip) : nil
    end

    # Deletes a ref by its full name (e.g. `"refs/heads/old-branch"`).
    # Removes the loose ref file and rewrites `packed-refs` without the entry.
    # Silently succeeds when the ref does not exist.
    def delete_ref(name : String) : Nil
      loose = @git_dir.join(name)
      @git_dir.delete(loose) if @git_dir.exists?(loose)

      packed_path = @git_dir.join(PACKED_REFS)
      return unless @git_dir.exists?(packed_path)
      lines = @git_dir.read_lines(packed_path)
      filtered = lines.reject do |line|
        next false if line.starts_with?('#') || line.starts_with?('^')
        parts = line.strip.split(' ', 2)
        parts.size == 2 && parts[1] == name
      end
      return if filtered.size == lines.size
      LockFile.write(packed_path, @git_dir) { |io| filtered.each { |line| io.print(line.ends_with?('\n') ? line : line + "\n") } }
    end

    # Appends one entry to `.git/logs/<ref_name>`, creating the file and parent dirs as needed.
    # Uses a static identity (`crystal-git <>`) since the library has no user context.
    #
    # ### Parameters
    #
    # *old_oid* — Previous tip; use the all-zeros OID (`"0" * 40`) when creating a ref for the first time.
    def append_reflog(ref_name : String, old_oid : Object::Id, new_oid : Object::Id, message : String) : Nil
      path = @git_dir.join("logs", ref_name)
      @git_dir.mkdir_p(File.dirname(path))
      ts = Time.utc.to_unix
      @git_dir.open(path, "a") { |io| io.print("#{old_oid.to_hex} #{new_oid.to_hex} crystal-git <> #{ts} +0000\t#{message}\n") }
    end

    # Writes a minimal `.git/config` with `[core]` settings and an `origin` remote pointing to *remote_url*.
    def write_config(remote_url : String) : Nil
      LockFile.write(@git_dir.join("config"), @git_dir) do |io|
        io.print("[core]\n")
        io.print("\trepositoryformatversion = 0\n")
        io.print("\tfilemode = true\n")
        io.print("\tbare = false\n")
        io.print("[remote \"origin\"]\n")
        io.print("\turl = #{remote_url}\n")
        io.print("\tfetch = +refs/heads/*:refs/remotes/origin/*\n")
      end
    end

    # Writes all *refs* to `packed-refs`, sorted by name.
    def write_packed_refs(refs : Array(Ref)) : Nil
      LockFile.write(@git_dir.join(PACKED_REFS), @git_dir) do |io|
        io.print("# pack-refs with: peeled fully-peeled sorted\n")
        refs.sort_by(&.name).each do |ref|
          io.print(ref.oid.to_hex)
          io.print(" ")
          io.print(ref.name)
          io.print("\n")
        end
      end
    end

    # Returns the shallow boundary commit OIDs from `.git/shallow`.
    # Returns an empty array for full (non-shallow) repositories.
    def read_shallow : Array(Object::Id)
      path = @git_dir.join(SHALLOW_FILE)
      return [] of Object::Id unless @git_dir.file?(path)
      @git_dir.read_lines(path).compact_map do |line|
        hex = line.strip
        hex.empty? ? nil : Git.oid(hex)
      end
    end

    # Writes the shallow boundary OIDs to `.git/shallow`.
    # Deletes the file when *oids* is empty (making the repo non-shallow).
    def write_shallow(oids : Array(Object::Id)) : Nil
      path = @git_dir.join(SHALLOW_FILE)
      if oids.empty?
        @git_dir.delete(path) if @git_dir.file?(path)
      else
        LockFile.write(path, @git_dir) { |io| io.print(oids.map(&.to_hex).join("\n") + "\n") }
      end
    end

    # Writes HEAD as a detached reference pointing directly to *oid*.
    def write_detached_head(oid : Object::Id) : Nil
      LockFile.write(@git_dir.join(HEAD_FILE), @git_dir) { |io| io.print(oid.to_hex + "\n") }
    end

    # Returns the OID the working tree currently points to.
    # Handles both branch (symbolic ref) and detached HEAD.
    def read_head_oid : Object::Id
      head = @git_dir.read(@git_dir.join(HEAD_FILE)).strip
      if head.starts_with?(SYMREF_PREFIX)
        branch_tip(head[SYMREF_PREFIX.size..])
      else
        Git.oid(head)
      end
    end

    # Returns the path where the received packfile should be written.
    # Generates a random name on first call and caches it.
    def packfile_path : String
      @packfile_path ||= @git_dir.join(
        "objects", "pack",
        "pack-#{Random::Secure.hex(20)}.pack"
      )
    end
  end
end
