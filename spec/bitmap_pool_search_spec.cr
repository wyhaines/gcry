require "./spec_helper"

class Gcry::Heap
  property fail_pool_growth_for_spec = false

  private def bitmap_directory_resize(dir : Gcry::BitmapClassDirectory*, capacity : Int32) : Bool
    return false if @fail_pool_growth_for_spec && capacity > dir.value.capacity
    previous_def
  end

  def full_pool_chunk_representatives_for_spec(count : Int32) : Array(Void*)
    first = malloc(8192)
    blocks = chunk_block_count(chunk_for(first).not_nil!).to_i
    users = Array.new(count) do |i|
      user = i == 0 ? first : malloc(8192)
      (blocks - 1).times { malloc(8192) }
      user
    end
    # Keep the active cursor out of the set we free and rediscover.
    blocks.times { malloc(8192) }
    users.sort_by!(&.address)
  end

  def pool_directory_bytes_for_spec
    @bitmap_directories.sum { |dir| dir.capacity.to_i64 * sizeof(Gcry::ChunkHeader*) }
  end

  def pool_directory_fallbacks_for_spec : Int32
    @bitmap_directories.count(&.fallback)
  end

  def check_pool_membership_for_spec : Nil
    expected = [] of UInt64
    each_chunk do |chunk|
      next if Gcry::ChunkHeader.large?(chunk) || Gcry::ChunkHeader.nursery?(chunk) || Gcry::ChunkHeader.reserve?(chunk)
      expected << chunk.address
    end
    found = [] of UInt64
    POOL_SLOTS.times do |slot|
      each_bitmap_pool_member(slot) do |chunk|
        block = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(chunk.value.size_class.to_i32)
        offset = Gcry::Heap.chunk_geometry(block, chunk.value.mapped_bytes, true)[1]
        chunk.value.data_offset.should eq(offset)
        bitmap_capacity_slot(chunk).should eq(slot)
        bitmap_pool_linked?(slot, chunk).should be_true
        found << chunk.address
      end
    end
    found.sort!.should eq(expected.sort!)
  end

  def check_wrapped_pool_position_for_spec : Nil
    # Model a class with > 65536 chunks without mapping gigabytes of payload.
    dir = Gcry::BitmapClassDirectory.new
    count = Gcry::ChunkHeader::POOL_POSITION_STRIDE + 3
    bitmap_directory_resize(pointerof(dir), count).should be_true
    begin
      header = Gcry::ChunkHeader.new(Pointer(Gcry::ChunkHeader).null, 4096_u64, 1_u32, Gcry::ChunkHeader::Flags::ATOMIC)
      at = count - 1
      dir.entries[at % Gcry::ChunkHeader::POOL_POSITION_STRIDE] = Pointer(Gcry::ChunkHeader).null
      dir.entries[at] = pointerof(header)
      dir.count = count
      Gcry::ChunkHeader.set_pool_position(pointerof(header), at)
      Gcry::ChunkHeader.atomic?(pointerof(header)).should be_true
      bitmap_directory_position(pointerof(dir), pointerof(header)).should eq(at)
    ensure
      dir.count = 0
      bitmap_directory_resize(pointerof(dir), 0)
    end
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
  it "resolves positions beyond the flag bits reserved for the directory" do
    heap = Gcry::Heap.new
    begin
      heap.check_wrapped_pool_position_for_spec
    ensure
      heap.destroy
    end
  end

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
      representatives = heap.full_pool_chunk_representatives_for_spec(7)
      [2, 6, 4, 5, 1].each { |i| heap.free(representatives[i]) }
      heap.malloc(8192).should eq(representatives[1])
      visits = heap.bitmap_pool_chunk_visits
      heap.free(representatives[0])
      heap.malloc(8192).should eq(representatives[0])
      heap.free(representatives[3])
      [2, 3, 4, 5, 6].each { |i| heap.malloc(8192).should eq(representatives[i]) }
      heap.bitmap_pool_chunk_visits.should eq(visits)
    ensure
      heap.destroy
    end
  end

  it "rediscovers a burst of frees without visiting the class directory" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      users = heap.full_pool_chunk_representatives_for_spec(8)
      visits = heap.bitmap_pool_chunk_visits
      [1, 4, 0, 6].each { |i| heap.free(users[i]) }
      [0, 1, 4, 6].each { |i| heap.malloc(8192).should eq(users[i]) }
      heap.bitmap_pool_chunk_visits.should eq(visits)
    ensure
      heap.destroy
    end
  end

  it "shrinks each directory with its live class and frees an empty directory" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.blacklist_enabled = false
      heap.nursery_enabled = false
      heap.release_empty_chunks = true
      heap.empty_chunk_retain = 0_u64
      heap.gc_threshold = UInt64::MAX
      keep = heap.full_pool_chunk_representatives_for_spec(48)[3]
      floor = Gcry::BitmapClassDirectory::MIN_CAPACITY * sizeof(Gcry::ChunkHeader*)
      heap.pool_directory_bytes_for_spec.should be > floor
      heap.collect(scan_stack: false, roots: [keep], release_warm: true)
      heap.live?(keep).should be_true
      heap.pool_directory_bytes_for_spec.should eq(floor)
      heap.collect(scan_stack: false, release_warm: true)
      heap.pool_directory_bytes_for_spec.should eq(0)
    ensure
      heap.destroy
    end
  end

  it "can still reuse freed chunks when the optional directory cannot grow" do
    heap = Gcry::Heap.new
    heap.fail_pool_growth_for_spec = true
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      users = heap.full_pool_chunk_representatives_for_spec(7)
      heap.pool_directory_fallbacks_for_spec.should eq(1)
      users.each { |user| heap.free(user) }
      users.each { |user| heap.malloc(8192).should eq(user) }
      heap.release_empty_chunks = true
      heap.empty_chunk_retain = 0_u64
      heap.empty_chunk_warm_retain = 0_u64
      heap.collect(scan_stack: false, release_warm: true)
      heap.pool_directory_fallbacks_for_spec.should eq(0)
      heap.fail_pool_growth_for_spec = false
      heap.malloc(8192).null?.should be_false
      heap.pool_directory_fallbacks_for_spec.should eq(0)
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

  it "keeps class membership across release and reuse" do
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
