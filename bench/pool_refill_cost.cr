# Count class-local chunk visits as the small-object live set grows. The
# disabled arm forces discovery on every refill to check the rebuild gate.
# Run all three arms with `make pool-refill-cost`.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "pool_refill_cost requires -Dgc_none (gcry as process GC)" %}
{% end %}

PHASES      = [1, 4, 16, 64]
ROUNDS      = (ENV["POOL_ROUNDS"]?.try(&.to_i?) || 40)
PER_ROUND   = (ENV["POOL_PER_ROUND"]?.try(&.to_i?) || 4096)
ALLOC_BYTES = 256

heap = Gcry.default_heap.not_nil!
churn = ARGV.includes?("--churn")
disabled = ARGV.includes?("--disabled")
if disabled && !heap.pool_index_disabled
  STDERR.puts "--disabled needs GCRY_DISABLE_POOL_INDEX=1: this arm measures the cost of rebuilding on every refill."
  exit 64
end

puts "=== how does the refill walk scale with the chunk count? ==="
puts "#{PHASES.size} phases, #{ROUNDS} rounds x #{PER_ROUND} allocations of #{ALLOC_BYTES} B each, " \
     "#{churn ? "live set dropped every round (churn)" : "live set kept per phase"}" \
     "#{disabled ? ", index skipped (GCRY_DISABLE_POOL_INDEX=1)" : ""}"
puts ""
puts "  live rounds   chunks   allocations   rebuilds   per 1k allocs   chunk visits / alloc"

record Phase, chunks : UInt64, allocs : UInt64, rebuilds : UInt64, visits : Float64

results = [] of Phase
live = [] of Array(UInt8)
PHASES.each do |keep|
  live.clear
  # Grow the live set for this phase, so the class has more chunks to walk.
  (keep * PER_ROUND).times { live << Array(UInt8).new(ALLOC_BYTES, 1_u8) }
  GC.collect
  before = heap.bitmap_pool_searches
  visits_before = heap.bitmap_pool_chunk_visits
  allocs = 0_u64
  ROUNDS.times do
    PER_ROUND.times do
      garbage = Array(UInt8).new(ALLOC_BYTES, 2_u8)
      allocs += 1
      garbage.size
    end
    live.clear if churn
    GC.collect
  end
  rebuilds = heap.bitmap_pool_searches - before
  chunks = heap.size_class_chunk_count
  visits = allocs > 0 ? (heap.bitmap_pool_chunk_visits - visits_before).to_f / allocs : 0.0
  results << Phase.new(chunks, allocs, rebuilds, visits)
  puts "  #{keep.to_s.rjust(11)}   #{chunks.to_s.rjust(6)}   #{allocs.to_s.rjust(11)}" \
       "   #{rebuilds.to_s.rjust(8)}   #{(rebuilds * 1000.0 / allocs).round(2).to_s.rjust(13)}" \
       "   #{visits.round(4).to_s.rjust(20)}"
end

puts ""
first, last = results.first, results.last
if last.rebuilds == 0 && first.rebuilds == 0
  if disabled
    puts "FAIL not one rebuild with the index skipped — GCRY_DISABLE_POOL_INDEX no longer"
    puts "invalidates the pool index, so the only way this gate can fail is a hand edit of"
    puts "the rebuild floor again."
    exit 1
  end
  puts "ok — not one rebuild in #{results.sum(&.allocs)} allocations at any size: the walk is not"
  puts "on the refill path on this workload, so O(chunks) per refill does not describe it."
  exit 0
end

growth = first.chunks > 0 ? last.chunks.to_f / first.chunks : 0.0
cost_growth = first.visits > 0 ? last.visits / first.visits : Float64::INFINITY
puts "chunks grew #{growth.round(2)}x across the phases; chunk visits per allocation grew " \
     "#{cost_growth.round(2)}x."

rebuilds_per_collection = results.sum(&.rebuilds).to_f / (PHASES.size * ROUNDS)
puts "#{rebuilds_per_collection.round(2)} rebuilds per collection."
if disabled ? rebuilds_per_collection <= 8.0 : rebuilds_per_collection > 8.0
  puts "FAIL: unexpected rebuild rate with pool index #{disabled ? "disabled" : "enabled"}"
  exit 1
end
puts "ok"
