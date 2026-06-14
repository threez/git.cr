module Git
  module Object
    # Minimal read interface shared by `Pack::Resolver` and `Object::Store`.
    # Depend on this abstraction rather than the concrete types in Worktree code.
    abstract class BlobSource
      abstract def [](oid : Id) : {Pack::ObjectType, Bytes}?

      # Returns a BlobSource that tries *primary* first, then falls back to *fallback*.
      # Use this in call sites that have both a freshly received pack and a local store.
      def self.compose(primary : BlobSource, fallback : BlobSource) : BlobSource
        ComposedBlobSource.new(primary, fallback)
      end
    end

    private class ComposedBlobSource < BlobSource
      def initialize(@primary : BlobSource, @fallback : BlobSource)
      end

      def [](oid : Id) : {Pack::ObjectType, Bytes}?
        @primary[oid] || @fallback[oid]
      end
    end
  end
end
