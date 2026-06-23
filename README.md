# lz4rip — Ractor-safe LZ4 for Ruby

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

## API

| Class / Module | Method | Description |
|---|---|---|
| `Lz4rip::FrameCodec` | `.new(dict: nil)` | Create a frame codec, optionally with a `Dictionary` or raw `String` dict |
| | `#compress(string)` | Compress to LZ4 frame |
| | `#decompress(string)` | Decompress an LZ4 frame |
| | `#has_dict?` | Whether a dictionary is loaded |
| | `#id` | Dictionary ID (nil without dict) |
| | `#size` | Dictionary size in bytes (0 without dict) |
| `Lz4rip::BlockCodec` | `.new(dict: nil)` | Create a block codec, optionally with a dict `String` |
| | `#compress(string)` | Compress to raw LZ4 block |
| | `#decompress(string, decompressed_size:)` | Decompress a raw LZ4 block |
| | `#has_dict?` | Whether a dictionary is loaded |
| | `#size` | Internal state size in bytes |
| `Lz4rip::Dictionary` | `.new(bytes:, id: auto)` | Immutable dictionary value object |
| | `#bytes` | Frozen binary dict bytes |
| | `#id` | 32-bit dictionary ID |
| | `#size` | Dictionary size in bytes |
| `Lz4rip::DictTrainer` | `.new(max_dict_size)` | Create a trainer (capped at 65535) |
| | `#add_sample(string)` | Feed a training sample |
| | `#train` | Consume the trainer, return dict bytes |
| | `#sample_count` | Number of accepted samples |
| | `#total_bytes` | Total bytes of accepted samples |
| | `#trained?` | Whether `#train` has been called |
| | `#max_dict_size` | Configured max dict size |
| `Lz4rip` | `.compress_bound(size)` | Max compressed output size for a given input size |
| | `.block_stream_size` | Internal compressor heap size |
| `Lz4rip::DecompressError` | | Raised on decompression failure (subclass of `StandardError`) |

## License

[MIT](LICENSE)
