# frozen_string_literal: true

Warning[:experimental] = false

require "minitest/autorun"
require "minitest/spec"
require "lz4rip"

module RactorTestHelpers
  def require_ractor
    skip "Ractor is unavailable on this Ruby VM" unless defined?(Ractor)
  end

  def ractor_value(ractor)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end
end

Minitest::Spec.include(RactorTestHelpers)
