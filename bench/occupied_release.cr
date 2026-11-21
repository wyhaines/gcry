# The sweep removes empty chunks from the class directory before flushing
# them. Exhaust a cursor in that window. The refill must map a fresh chunk,
# and every queued chunk must remain empty. Then ask the flush for its release
# decision on the newly allocated block, while its chunk is still mapped.
# The historical control (--broken) must give the opposite decision.
require "../src/gcry"
require "../process_spec/support/release_guard_heap"

SIZE = 4096_u64

broken = ARGV.includes?("--broken")

heap = Gcry::Heap.new
heap.bitmap_alloc = true
heap.nursery_enabled = false
heap.gc_threshold = UInt64::MAX
heap.release_empty_chunks = true
# The release is gated on the process having one mutator thread; these two
# only widen the multi-mutator branch and are what `spec/empty_chunk_grace_spec`
# uses for the same reason.
heap.parallel_empty_chunk_dormant = true
heap.parallel_empty_chunk_munmap = true
heap.empty_chunk_warm_retain = 0_u64
heap.empty_chunk_retain = 0_u64
# The window is between the after-world sweep and the flush; the in-STW sweep
# unlinks inside the stop and a pool built afterwards never sees the chunk.
heap.lazy_sweep = true
heap.release_occupied_anyway = broken

def chunk_of(heap : Gcry::Heap, p : Void*) : UInt64
  found = heap.find_block_with_chunk(p)
  raise "#{p} is not in the heap under test" unless found
  found[1].address
end

puts "=== bitmap refill during the release flush ==="
puts "mode: #{broken ? "legacy occupied-chunk decision" : "refuse an occupied chunk"}"

# 1. Several chunks of garbage; one major puts every chunk on grace.
blocks_per_chunk = heap.small_chunk_bytes // SIZE
(6 * blocks_per_chunk).times { heap.malloc(SIZE) }
heap.collect(scan_stack: false)
puts "chunks on grace after the first major: #{heap.empty_chunk_grace_kept}"

failures = [] of String
roots = [] of Void*
first_chunk = 0_u64
taken = Pointer(Void).null
taken_chunk = 0_u64
mapped_before = heap.chunks_mapped
refused_before = heap.release_refused_occupied
considered_before = heap.release_flush_chunks

heap.post_stw_hook = ->(stage : Symbol) do
  case stage
  when :after_start_world
    p = heap.malloc(SIZE)
    roots << p
    first_chunk = chunk_of(heap, p)
  when :before_flush
    n = 0
    loop do
      p = heap.malloc(SIZE)
      roots << p
      n += 1
      c = chunk_of(heap, p)
      if c != first_chunk
        taken = p
        taken_chunk = c
        break
      end
      if n > blocks_per_chunk + 1
        failures << "the cursor never left chunk 0x#{first_chunk.to_s(16)} in #{n} allocations"
        break
      end
    end
  end
end

# 2. The second major queues the idle chunks. Refill before the flush.
heap.collect(scan_stack: false, roots: roots)
heap.post_stw_hook = nil

refused = heap.release_refused_occupied - refused_before
considered = heap.release_flush_chunks - considered_before
fresh_maps = heap.chunks_mapped - mapped_before

puts "chunks the flush considered:      #{considered}"
puts "chunks the flush found occupied: #{refused}"
puts "chunks mapped during the window: #{fresh_maps}"
puts "block taken in the window:       #{taken} in chunk 0x#{taken_chunk.to_s(16)}"

failures << "no block was taken in the window" if taken.null?
failures << "refill should map one fresh chunk (#{fresh_maps} mapped)" unless fresh_maps == 1
failures << "the sweep queued no chunks" if considered == 0
failures << "refill occupied a queued chunk" unless refused == 0
unless taken.null?
  failures << "the new block should still be allocated" unless heap.live?(taken)
  decision = heap.would_refuse_release_for_spec?(taken)
  failures << "unexpected occupied-chunk release decision: #{decision}" unless decision == !broken
  failures << "the occupied-block check never fired" unless heap.release_refused_occupied == refused_before + 1
end
heap.destroy
abort failures.join("\n") unless failures.empty?
puts "ok — refill skipped queued chunks and the occupied-chunk release decision matched this arm"
