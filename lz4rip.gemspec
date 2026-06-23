# frozen_string_literal: true

require_relative "lib/lz4rip/version"

Gem::Specification.new do |s|
  s.name     = "lz4rip"
  s.version  = Lz4rip::VERSION
  s.authors  = ["Patrik Wenger"]
  s.email    = ["paddor@gmail.com"]
  s.summary  = "Ractor-safe LZ4 compression for Ruby"
  s.description = "Ruby bindings (via Rust/magnus) for lz4rip, a pure-Rust " \
                  "LZ4 implementation. Block-format and frame-format " \
                  "compress/decompress with optional dictionary support " \
                  "and COVER-based dictionary training. Ractor-safe."
  s.homepage = "https://github.com/paddor/lz4rip-rb"
  s.license  = "MIT"

  s.required_ruby_version = ">= 4.0.0"

  s.metadata["homepage_uri"]      = s.homepage
  s.metadata["source_code_uri"]   = s.homepage
  s.metadata["changelog_uri"]     = "#{s.homepage}/blob/main/CHANGELOG.md"
  s.metadata["rubygems_mfa_required"] = "true"

  s.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rs,rb}",
    "ext/**/Cargo.toml",
    "Cargo.toml",
    "Cargo.lock",
    "LICENSE",
    "README.md",
    "CHANGELOG.md",
  ]

  s.require_paths = ["lib"]
  s.extensions    = ["ext/lz4rip/extconf.rb"]

  s.add_dependency "rb_sys", "~> 0.9"
end
