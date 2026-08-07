# frozen_string_literal: true

require_relative "lz4rip/lz4rip"        # Rust extension
require_relative "lz4rip/version"
require_relative "lz4rip/dictionary"
require_relative "lz4rip/block_codec"
require_relative "lz4rip/frame_codec"
require_relative "lz4rip/dict_trainer"

# Ractor-safe LZ4 compression for Ruby.
#
# @!method self.compress_bound(size)
#   Return the maximum compressed output size for input bytes.
#   @param size [Integer] input size in bytes
#   @return [Integer]
#
# @!method self.block_stream_size
#   Return the native block compressor heap size.
#   @return [Integer]
#
# @!parse
#   # Raised when LZ4 decompression fails.
#   class DecompressError < StandardError; end
module Lz4rip
end
