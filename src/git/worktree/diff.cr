module Git
  module Worktree
    # A single file-system change between two tree states.
    # For `Deleted` entries, `oid` is nil and `mode` is zero.
    struct Change
      enum Kind
        # File did not exist in the old tree.
        Added
        # File exists in both trees with different content or mode.
        Modified
        # File existed in the old tree only.
        Deleted
      end

      # Whether the entry was `Added`, `Modified`, or `Deleted`.
      getter kind : Kind

      # Repo-relative path of the changed file (e.g. `"src/main.cr"`).
      getter path : String

      # SHA-1 of the new blob, or `nil` for `Deleted` entries.
      getter oid : Object::Id?

      # Git file mode of the new entry (e.g. `0o100644`), or `0` for `Deleted`.
      getter mode : UInt32

      def initialize(@kind, @path, @oid = nil, @mode = 0_u32)
      end
    end

    # Recursive diff between two tree objects, producing a flat list of file-level changes.
    # Descends into subdirectories automatically.
    module Diff
      # Compares *old_tree* and *new_tree* and returns all file-level `Change`s.
      #
      # ### Parameters
      #
      # *old_tree* — Root tree OID before the change, or `nil` for an empty tree (e.g. initial clone).
      #
      # *new_tree* — Root tree OID after the change, or `nil` for a full delete.
      #
      # *store* — Object store used to resolve tree and blob OIDs.
      #
      # *new_objects* — Optional resolver consulted before *store* for objects in a freshly received pack.
      # ameba:disable Metrics/CyclomaticComplexity
      def self.diff(
        old_tree : Object::Id?,
        new_tree : Object::Id?,
        source : Object::BlobSource,
        prefix : String = "",
      ) : Array(Change)
        changes = [] of Change

        old_entries = old_tree ? parse_tree(old_tree, source) : [] of Object::TreeEntry
        new_entries = new_tree ? parse_tree(new_tree, source) : [] of Object::TreeEntry

        old_map = old_entries.to_h { |e| {e.name, e} }
        new_map = new_entries.to_h { |e| {e.name, e} }

        all_names = (old_map.keys + new_map.keys).uniq

        all_names.each do |name|
          path = prefix.empty? ? name : "#{prefix}/#{name}"
          old_e = old_map[name]?
          new_e = new_map[name]?

          if old_e.nil? && new_e
            # Added
            if new_e.directory?
              changes.concat diff(nil, new_e.oid, source, path)
            else
              changes << Change.new(Change::Kind::Added, path, new_e.oid, new_e.mode)
            end
          elsif old_e && new_e.nil?
            # Deleted
            if old_e.directory?
              changes.concat diff(old_e.oid, nil, source, path)
            else
              changes << Change.new(Change::Kind::Deleted, path)
            end
          elsif old_e && new_e && old_e.oid != new_e.oid
            # Changed — handle type transitions (file↔directory) by emitting explicit
            # Deleted entries for the old side before Added/Modified for the new side.
            if new_e.directory?
              if old_e.directory?
                changes.concat diff(old_e.oid, new_e.oid, source, path)
              else
                # file → directory: delete the old file, then add all new tree entries.
                changes << Change.new(Change::Kind::Deleted, path)
                changes.concat diff(nil, new_e.oid, source, path)
              end
            else
              if old_e.directory?
                # directory → file: delete all old tree entries, then add the new file.
                changes.concat diff(old_e.oid, nil, source, path)
                changes << Change.new(Change::Kind::Added, path, new_e.oid, new_e.mode)
              else
                changes << Change.new(Change::Kind::Modified, path, new_e.oid, new_e.mode)
              end
            end
          end
          # else unchanged
        end

        changes
      end

      private def self.parse_tree(oid : Object::Id, source : Object::BlobSource) : Array(Object::TreeEntry)
        result = source[oid]
        raise Error.new("Tree object #{oid.to_hex} not found") unless result
        Object::Tree.parse(result[1])
      end
    end
  end
end
