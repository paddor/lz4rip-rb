# frozen_string_literal: true

require "digest"

module Lz4rip
  # Immutable LZ4 dictionary value.
  #
  # @!attribute [r] bytes
  #   @return [String] frozen binary dictionary bytes
  #
  # @!attribute [r] id
  #   @return [Integer] dictionary ID
  Dictionary = Data.define(:bytes, :id) do
    # @param bytes [String] dictionary bytes
    # @param id [Integer] optional dictionary ID
    def initialize(bytes:, id: Digest::SHA256.digest(bytes).byteslice(0, 4).unpack1("V"))
      super(bytes: bytes.b.freeze, id: id)
    end


    # @return [Integer] dictionary size in bytes
    def size
      bytes.bytesize
    end
  end
end
