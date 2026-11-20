require "./spec_helper"

class Gcry::Heap
  def check_pool_membership_for_spec : Nil
    expected = [] of UInt64
    each_chunk do |chunk|
      next if Gcry::ChunkHeader.large?(chunk) || Gcry::ChunkHeader.nursery?(chunk) || Gcry::ChunkHeader.reserve?(chunk)
      expected << chunk.address
    end
    found = [] of UInt64
    POOL_SLOTS.times do |slot|
      prev = Pointer(Gcry::ChunkHeader).null
      each_bitmap_pool_member(slot) do |chunk|
        bitmap_capacity_slot(chunk).should eq(slot)
        bitmap_pool_links(chunk).value.previous.should eq(prev)
        found << chunk.address
        prev = chunk
      end
    end
    found.sort!.should eq(expected.sort!)
  end

  def pool_index_at_stw_for_spec(address : UInt64) : UInt64
    @index_lock.lock
    @world_stopped = true
    begin
      bitmap_indexed_chunk(address).try(&.address) || 0_u64
    ensure
      @world_stopped = false
      @index_lock.unlock
    end
  end
end

describe "bitmap pool capacity search" do
  it "resolves mapping keys without waiting on a stopped mutator's index lock" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.malloc(8192)
      address = 0_u64
      heap.each_chunk { |chunk| address = chunk.address }
      heap.pool_index_at_stw_for_spec(address).should eq(address)
    ensure
      heap.destroy
    end
  end

  it "does not repeat an empty search while growing an occupied class" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = true
      200.times { heap.malloc(8192) }
      heap.bitmap_pool_searches.should eq(1)
      heap.bitmap_pool_search_skips.should be > 10
      # Atomic capacity is a different pool, even at the same size.
      200.times { heap.malloc_atomic(8192) }
      heap.bitmap_pool_searches.should eq(2)
    ensure
      heap.destroy
    end
  end

  it "skips unrelated mappings and rechecks one changed chunk directly" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.blacklist_enabled = false
      heap.gc_threshold = UInt64::MAX
      128.times { heap.malloc(40 * 1024) }
      200.times { heap.malloc_atomic(8192) }
      visits = heap.bitmap_pool_chunk_visits
      first = heap.malloc(8192)
      199.times { heap.malloc(8192) }
      heap.bitmap_pool_chunk_visits.should eq(visits)
      heap.free(first)
      Array.new(32) { heap.malloc(8192) }.should contain(first)
      heap.bitmap_pool_chunk_visits.should eq(visits)
    ensure
      heap.destroy
    end
  end

  it "finds an explicitly freed block after a cached empty search" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      first = heap.malloc(8192)
      199.times { heap.malloc(8192) }
      heap.free(first)
      found = false
      # At most one current chunk's tail remains ahead of the freed block.
      32.times { found = true if heap.malloc(8192) == first }
      found.should be_true
    ensure
      heap.destroy
    end
  end

  it "merges a single free into the remaining candidates in address order" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      first = heap.malloc(8192)
      blocks = 0
      heap.each_chunk do |chunk|
        blocks = Gcry::Heap.chunk_block_count((8192 + Gcry::BlockHeader::SIZE).to_u64,
          chunk.value.mapped_bytes, chunk.value.data_offset).to_i
      end
      pointers = [first]
      (5 * blocks - 1).times { pointers << heap.malloc(8192) }
      representatives = pointers.each_slice(blocks).map(&.first).to_a.sort_by(&.address)
      [2, 4, 1].each { |i| heap.free(representatives[i]) }
      heap.malloc(8192).should eq(representatives[1])
      visits = heap.bitmap_pool_chunk_visits
      heap.free(representatives[0])
      heap.malloc(8192).should eq(representatives[0])
      heap.free(representatives[3])
      [2, 3, 4].each { |i| heap.malloc(8192).should eq(representatives[i]) }
      heap.bitmap_pool_chunk_visits.should eq(visits)
    ensure
      heap.destroy
    end
  end

  it "reuses swept capacity and retired partially occupied cursors" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      heap.release_empty_chunks = false
      keep = heap.malloc(8192)
      199.times { heap.malloc(8192) }
      size = heap.heap_size
      heap.collect(scan_stack: false, roots: [keep])
      199.times { heap.malloc(8192) }
      heap.heap_size.should eq(size)
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end

  it "keeps class membership and back-links across release and reuse" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      heap.release_empty_chunks = true
      heap.empty_chunk_retain = 0_u64
      heap.empty_chunk_warm_retain = 0_u64
      2.times do
        100.times do
          heap.malloc(8192)
          heap.malloc_atomic(4096)
        end
        heap.check_pool_membership_for_spec
        2.times do
          heap.collect(scan_stack: false)
          heap.check_pool_membership_for_spec
        end
      end
      heap.unmapped_bytes.should be > 0
    ensure
      heap.destroy
    end
  end

  it "rediscovers capacity when blacklisting is disabled" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = true
      first = heap.malloc(8192)
      199.times { heap.malloc(8192) }
      heap.free(first)
      heap.blacklist_address(first.address)
      32.times { heap.malloc(8192).should_not eq(first) }
      heap.blacklist_enabled = false
      found = false
      32.times { found = true if heap.malloc(8192) == first }
      found.should be_true
    ensure
      heap.destroy
    end
  end

  it "publishes a block freed behind a cursor when that cursor retires" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      first = heap.malloc(48)
      blocks = 0_u64
      heap.each_chunk do |chunk|
        if Gcry::ChunkHeader.contains?(chunk, first.address)
          blocks = Gcry::Heap.chunk_block_count(
            (Gcry::BlockHeader::SIZE + 48).to_u64,
            chunk.value.mapped_bytes, chunk.value.data_offset)
        end
      end
      blocks.should be > 64
      (blocks - 1).times { heap.malloc(48) }
      heap.free(first)
      # This thread searches while the main cursor still owns the chunk,
      # caching absence despite the free bit in an earlier bitmap word.
      Thread.new { heap.malloc(48) }.join
      heap.malloc(48).should eq(first)
    ensure
      heap.destroy
    end
  end
end
