module Git
  # Parses `.gitmodules` and initializes / updates submodule working trees.
  module Repository::Submodule
    # Injected by the caller (typically `Client`) to clone a new submodule.
    alias CloneCallback = Proc(String, String, Nil)
    # Injected by the caller to reset an existing submodule to its recorded commit.
    alias ResetCallback = Proc(String, Nil)
    # Injected by the caller to pin a working tree to a specific OID.
    alias PinCallback = Proc(String, Object::Id, Nil)

    # One `[submodule "name"]` stanza from `.gitmodules`.
    struct Entry
      # Submodule name as written in the `[submodule "name"]` stanza.
      getter name : String

      # Working-tree path where the submodule is checked out, relative to the parent root.
      getter path : String

      # Remote URL declared in `.gitmodules` (may be relative to the parent remote).
      getter url : String

      def initialize(@name, @path, @url)
      end
    end

    # Reads all submodule entries from `<work_dir>/.gitmodules`.
    # Returns an empty array when the file is absent.
    def self.read_gitmodules(work_dir : String, fs : FileSystem = FileSystem::Local.new) : Array(Entry)
      config_path = File.join(work_dir, ".gitmodules")
      return [] of Entry unless fs.file?(config_path)
      config = Config.parse(fs.read(config_path))
      entries = [] of Entry
      config.sections.each do |key, vals|
        next unless key.starts_with?("submodule.")
        name = key["submodule.".size..]
        sub_path = vals["path"]? || name
        url = vals["url"]? || next
        entries << Entry.new(name, sub_path, url)
      end
      entries
    end

    # Returns the resolved absolute URL for *url* relative to *parent_remote*.
    # Absolute URLs are returned unchanged.
    def self.resolve_url(url : String, parent_remote : Transport::RemoteURL) : String
      Transport::RemoteURL.resolve_relative(url, parent_remote).original
    end

    # Clones all submodules declared in `<work_dir>/.gitmodules` after an initial checkout.
    # Submodule commit OIDs are read from the parent's HEAD tree via *store*.
    #
    # ### Parameters
    #
    # *store* — Object store for the parent repository; used to read the HEAD tree and resolve gitlinks.
    #
    # *clone_sub* — Called with `(url, into_dir)` for each submodule that needs cloning.
    # Callers inject the actual clone operation so that `Submodule` has no dependency on `Client`.
    #
    # *pin_sub* — Optional override for the default `pin_to_oid` logic; called with `(work_dir, oid)`.
    def self.init_all(
      work_dir : String,
      parent_git_dir : String,
      parent_remote : Transport::RemoteURL,
      store : Object::Store,
      lfs : Bool,
      on_progress : Protocol::ProgressCallback?,
      credentials : Transport::Credentials? = nil,
      clone_sub : CloneCallback = CloneCallback.new { |_, _| },
      pin_sub : PinCallback? = nil,
      fs : FileSystem = FileSystem::Local.new,
    ) : Nil
      entries = read_gitmodules(work_dir, fs)
      return if entries.empty?

      effective_pin = pin_sub || ->(dir : String, oid : Object::Id) { pin_to_oid(dir, oid) }

      repo = Repository.new(FileSystem::Local.new(parent_git_dir))
      head = repo.read_head_oid
      gitlinks = collect_gitlinks(head, store)

      entries.each do |entry|
        pinned_oid = gitlinks[entry.path]? || next
        resolved_url = resolve_url(entry.url, parent_remote)
        sub_work_dir = File.join(work_dir, entry.path)
        next if fs.directory?(sub_work_dir) && !fs.dir_empty?(sub_work_dir)
        clone_sub.call(resolved_url, sub_work_dir)
        effective_pin.call(sub_work_dir, pinned_oid)
      end
    end

    # Updates submodules after an incremental pull/sync/reset.
    # Gitlink entries (mode `0o160000`) in *changes* trigger clone or reset as appropriate.
    #
    # ### Parameters
    #
    # *changes* — Flat list of `Tree::Change`s produced by `Tree::Diff`.
    #
    # *clone_sub* — Called with `(url, into_dir)` for newly added submodules.
    #
    # *reset_sub* — Called with `(work_dir)` when a submodule's pinned commit changed.
    #
    # Callers inject *clone_sub* and *reset_sub* so that `Submodule` has no dependency on `Client`.
    def self.update_all(
      work_dir : String,
      parent_git_dir : String,
      parent_remote : Transport::RemoteURL,
      changes : Array(Worktree::Change),
      lfs : Bool,
      on_progress : Protocol::ProgressCallback?,
      credentials : Transport::Credentials? = nil,
      clone_sub : CloneCallback = CloneCallback.new { |_, _| },
      reset_sub : ResetCallback = ResetCallback.new { |_| },
      pin_sub : PinCallback? = nil,
      fs : FileSystem = FileSystem::Local.new,
    ) : Nil
      entries = read_gitmodules(work_dir, fs)
      return if entries.empty?

      effective_pin = pin_sub || ->(dir : String, oid : Object::Id) { pin_to_oid(dir, oid) }
      entry_map = entries.to_h { |e| {e.path, e} }

      changes.each do |change|
        next unless change.mode == 0o160000_u32
        entry = entry_map[change.path]? || next
        resolved_url = resolve_url(entry.url, parent_remote)
        sub_work_dir = File.join(work_dir, change.path)

        pinned_oid = change.oid
        case change.kind
        when Worktree::Change::Kind::Added
          clone_sub.call(resolved_url, sub_work_dir)
          effective_pin.call(sub_work_dir, pinned_oid.not_nil!) if pinned_oid # ameba:disable Lint/NotNil
        when Worktree::Change::Kind::Modified
          if fs.directory?(sub_work_dir)
            reset_sub.call(sub_work_dir)
            effective_pin.call(sub_work_dir, pinned_oid.not_nil!) if pinned_oid # ameba:disable Lint/NotNil
          end
        end
      end
    end

    # Moves the submodule working tree at *work_dir* from its current HEAD to *pinned_oid*
    # by applying an incremental tree diff. Writes a detached HEAD. No-op if already there.
    private def self.pin_to_oid(work_dir : String, pinned_oid : Object::Id) : Nil
      sub_repo = Repository.open(FileSystem::Local.new(work_dir))
      store = Object::Store.new(sub_repo)

      current_oid = sub_repo.read_head_oid
      return if current_oid == pinned_oid

      current_result = store[current_oid] ||
                       raise Error.new("Submodule HEAD #{current_oid.to_hex} not found in object store")
      current_commit = Object::Commit.parse(current_result[1])

      pinned_result = store[pinned_oid] ||
                      raise Error.new("Pinned commit #{pinned_oid.to_hex} not found in submodule object store")
      pinned_commit = Object::Commit.parse(pinned_result[1])

      changes = Worktree::Diff.diff(current_commit.tree, pinned_commit.tree, store)
      Worktree::Checkout.apply_changes(FileSystem::Local.new(work_dir), store, changes)
      sub_repo.write_detached_head(pinned_oid)
    end

    # Walks the commit tree rooted at *head_oid* and returns all gitlink (mode 160000)
    # entries as a map from repo-relative path → commit Object::Id.
    private def self.collect_gitlinks(head_oid : Object::Id, store : Object::Store) : Hash(String, Object::Id)
      result = store[head_oid] || return {} of String => Object::Id
      _, data = result
      commit = Object::Commit.parse(data)
      collect_from_tree(commit.tree, "", store)
    end

    private def self.collect_from_tree(
      tree_oid : Object::Id,
      prefix : String,
      store : Object::Store,
    ) : Hash(String, Object::Id)
      result = {} of String => Object::Id
      tree_result = store[tree_oid] || return result
      _, tree_data = tree_result
      Object::Tree.parse(tree_data).each do |entry|
        path = prefix.empty? ? entry.name : "#{prefix}/#{entry.name}"
        if entry.gitlink?
          result[path] = entry.oid
        elsif entry.directory?
          result.merge!(collect_from_tree(entry.oid, path, store))
        end
      end
      result
    end
  end
end
