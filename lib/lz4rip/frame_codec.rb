# frozen_string_literal: true

require_relative "dictionary"

module Lz4rip
  # LZ4 frame-format codec.
  #
  # `FrameCodec` is Ractor-shareable.
  #
  # @!method self.new(dict: nil)
  #   Create a frame codec.
  #   @param dict [Dictionary, String, nil] optional LZ4 dictionary
  #   @return [FrameCodec]
  #
  # @!method self._native_new(dict, id)
  #   Native constructor used by `.new`.
  #   @param dict [String, nil] dictionary bytes
  #   @param id [Integer] dictionary ID, or `0` without a dictionary
  #   @return [FrameCodec]
  #
  # @!method compress(bytes)
  #   Compress bytes to an LZ4 frame.
  #   @param bytes [String] uncompressed bytes
  #   @return [String]
  #
  # @!method decompress(bytes, max_decompressed_size: nil)
  #   Decompress an LZ4 frame.
  #   @param bytes [String] compressed LZ4 frame
  #   @param max_decompressed_size [Integer, nil] optional output byte limit
  #   @return [String]
  #   @raise [DecompressError]
  #
  # @!method _decompress(bytes, max_decompressed_size)
  #   Native decompression entry used by #decompress.
  #   @param bytes [String] compressed LZ4 frame
  #   @param max_decompressed_size [Integer, nil] optional output byte limit
  #   @return [String]
  #   @raise [DecompressError]
  #
  # @!method has_dict?
  #   @return [Boolean]
  #
  # @!method id
  #   @return [Integer, nil] dictionary ID
  #
  # @!method size
  #   @return [Integer] dictionary size in bytes
  class FrameCodec
    def self.new(dict: nil)
      case dict
      when nil
        _native_new(nil, 0)
      when Dictionary
        _native_new(dict.bytes, dict.id)
      when String
        _native_new(dict, Dictionary.new(bytes: dict).id)
      else
        raise TypeError, "expected Lz4rip::Dictionary, String, or nil; got #{dict.class}"
      end
    end

    def decompress(bytes, max_decompressed_size: nil)
      _decompress(bytes, max_decompressed_size)
    end
  end
end
