# lz4rip: Ractor-safe LZ4 for Ruby

[![CI](https://github.com/paddor/lz4rip-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/paddor/lz4rip-rb/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/lz4rip?color=e9573f)](https://rubygems.org/gems/lz4rip)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%204.0-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

Ruby bindings for [lz4rip](https://crates.io/crates/lz4rip), a pure-Rust LZ4
implementation. Built with [magnus](https://github.com/matsadler/magnus) and
declared Ractor-safe so you can compress from any Ractor without a global lock.

## Features

- **Block codec** with reusable compressor scratch table
- **Frame codec** for standard `.lz4` frames
- **Dictionary support** for both block and frame codecs
- **COVER-based dictionary trainer** (`DictTrainer`)
- **Ractor-safe**: `FrameCodec` is shareable across Ractors, `BlockCodec` is
  per-Ractor (mutable scratch state)

## Install

Requires Ruby >= 4.0 and a Rust toolchain (for building the native extension):

```sh
gem install lz4rip
```

Or in your Gemfile:

```ruby
gem "lz4rip"
```

## Usage

### Frame codec (standard LZ4 frames)

```ruby
require "lz4rip"

codec = Lz4rip::FrameCodec.new
compressed = codec.compress("hello world " * 1000)
original   = codec.decompress(compressed)
bounded    = codec.decompress(compressed, max_decompressed_size: 12_000)
```

### Block codec (raw LZ4 blocks)

```ruby
codec = Lz4rip::BlockCodec.new
compressed = codec.compress("hello world " * 1000)
original   = codec.decompress(compressed, decompressed_size: 12_000)
```

Block decompression requires the original size up front. This is by design: LZ4
block format does not store it, so the caller must track it.

### Dictionary compression

```ruby
dict = Lz4rip::Dictionary.new(bytes: "common log prefix: ")
codec = Lz4rip::FrameCodec.new(dict: dict)

compressed = codec.compress("common log prefix: event=login user=alice")
original   = codec.decompress(compressed)
```

### Dictionary training

```ruby
trainer = Lz4rip::DictTrainer.new(2048)
messages.each { |msg| trainer.add_sample(msg) }
dict_bytes = trainer.train

dict  = Lz4rip::Dictionary.new(bytes: dict_bytes)
codec = Lz4rip::BlockCodec.new(dict: dict)
```

### Ractor safety

```ruby
codec = Lz4rip::FrameCodec.new

ractors = 4.times.map do |i|
  Ractor.new(codec) do |c|
    data = "ractor #{Ractor.current} payload " * 100
    ct   = c.compress(data)
    raise "mismatch" unless c.decompress(ct) == data
    :ok
  end
end

ractors.each { |r| p r.value }  # => :ok, :ok, :ok, :ok
```

## Documentation

Reference: <https://rubydoc.info/gems/lz4rip>

## License

[MIT](LICENSE)
