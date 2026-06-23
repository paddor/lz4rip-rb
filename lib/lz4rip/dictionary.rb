# frozen_string_literal: true

require "digest"

module Lz4rip
  Dictionary = Data.define(:bytes, :id) do
    def initialize(bytes:, id: Digest::SHA256.digest(bytes).byteslice(0, 4).unpack1("V"))
      super(bytes: bytes.b.freeze, id: id)
    end


    def size
      bytes.bytesize
    end
  end
end
