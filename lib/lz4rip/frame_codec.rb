# frozen_string_literal: true

require_relative "dictionary"

module Lz4rip
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
