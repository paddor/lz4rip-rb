# frozen_string_literal: true

require_relative "dictionary"

module Lz4rip
  class BlockCodec
    def self.new(dict: nil)
      _native_new(Dictionary === dict ? dict.bytes : dict)
    end


    def decompress(bytes, decompressed_size:)
      _decompress(bytes, decompressed_size)
    end
  end
end
