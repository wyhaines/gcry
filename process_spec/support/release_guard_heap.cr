# Exercise the flush decision on a real mapped chunk without detaching it.
# The allocator now rejects chunks queued for release before handing out a block.
class Gcry::Heap
  def would_refuse_release_for_spec?(block : Void*) : Bool
    refuse_occupied_release(chunk_for(block).not_nil!)
  end
end
