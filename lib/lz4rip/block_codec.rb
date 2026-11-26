# frozen_string_literal: true

require_relative "dictionary"

module Lz4rip
  # Raw LZ4 block-format codec.
  #
  # `BlockCodec` keeps mutable native scratch state and is intended to be used
  # per Ractor.
  #
  # @!method self.new(dict: nil)
  #   Create a block codec.
  #   @param dict [Dictionary, String, nil] optional LZ4 dictionary
  #   @return [BlockCodec]
  #
  # @!method self._native_new(dict)
  #   Native constructor used by `.new`.
  #   @param dict [String, nil] dictionary bytes
  #   @return [BlockCodec]
  #
  # @!method compress(bytes)
  #   Compress bytes to a raw LZ4 block.
  #   @param bytes [String] uncompressed bytes
  #   @return [String]
  #
  # @!method _decompress(bytes, decompressed_size)
  #   Native decompression entry used by #decompress.
  #   @param bytes [String] compressed LZ4 block
  #   @param decompressed_size [Integer] original byte size
  #   @return [String]
  #   @raise [DecompressError]
  #
  # @!method has_dict?
  #   @return [Boolean]
  #
  # @!method size
  #   @return [Integer] internal state size in bytes
  class BlockCodec
    def self.new(dict: nil)
      _native_new(Dictionary === dict ? dict.bytes : dict)
    end


    # Decompress a raw LZ4 block.
    #
    # `decompressed_size` is the original size, often declared by a peer. A
    # size the block cannot decode to (more than 255 times its length), or
    # above `max_decompressed_size`, raises before anything is allocated for
    # it.
    #
    # @param bytes [String] compressed LZ4 block
    # @param decompressed_size [Integer] original byte size
    # @param max_decompressed_size [Integer, nil] largest size to accept
    # @return [String]
    # @raise [DecompressError]
    def decompress(bytes, decompressed_size:, max_decompressed_size: nil)
      if max_decompressed_size && decompressed_size > max_decompressed_size
        raise DecompressError,
          "decompressed size #{decompressed_size} exceeds max_decompressed_size #{max_decompressed_size}"
      end

      _decompress(bytes, decompressed_size)
    end
  end
end
