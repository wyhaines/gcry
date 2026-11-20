# Process GC reserves one extra byte for atomic allocations. At Crystal's
# 32 KiB IO default that byte forces a separate large mapping for each buffer.
# Leave room in the largest small class. Explicit IO#buffer_size= still wins.
module IO::Buffered
  @buffer_size = IO::DEFAULT_BUFFER_SIZE == Gcry::SizeClasses::THRESHOLD ? IO::DEFAULT_BUFFER_SIZE - 1 : IO::DEFAULT_BUFFER_SIZE
end
