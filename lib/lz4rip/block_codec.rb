# frozen_string_literal: true

require_relative "dictionary"

module Lz4rip
  # Raw LZ4 block-format codec.
  #
  # `BlockCodec` keeps mutable native scratch state and is intended to be used
  # per Ractor.
  #
  # @!method self._native_new(dict, ratio)
  #   Native constructor used by `.new`.
  #   @param dict [String, nil] dictionary bytes
  #   @param ratio [Boolean] use the ratio profile
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
  #   Bytes the codec holds natively: its compressor tables made so far and
  #   its copies of the dictionary.
  #   @return [Integer]
  class BlockCodec
    PROFILES = %i[fast ratio].freeze


    # Create a block codec.
    #
    # The `:ratio` profile compresses to smaller output, more slowly, and
    # decodes with any LZ4 decoder. It holds an 8 KB table, plus 64 KB from
    # its first input above 4 KiB. With a dictionary it hashes the dictionary
    # once and holds 16 KB of tables while input and dictionary stay within
    # 4 KiB, 64 KB more for larger inputs. Either profile makes its compressor
    # on the first `#compress`, so a codec that only decompresses holds only
    # its dictionary.
    #
    # @param dict [Dictionary, String, nil] optional LZ4 dictionary
    # @param profile [Symbol] `:fast` or `:ratio`
    # @return [BlockCodec]
    # @raise [ArgumentError] on an unknown profile
    def self.new(dict: nil, profile: :fast)
      unless PROFILES.include?(profile)
        raise ArgumentError, "profile must be :fast or :ratio, got #{profile.inspect}"
      end

      _native_new(Dictionary === dict ? dict.bytes : dict, profile == :ratio)
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
