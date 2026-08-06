# Changelog

## [Unreleased]

- Release the Ruby GVL around large frame/block compression and frame
  decompression calls.
- Add `max_decompressed_size:` to `Lz4rip::FrameCodec#decompress`, with the
  cap enforced across concatenated frame output.
- Add RubyDoc metadata and move API reference details from `README.md` into
  YARD comments.

## [0.1.2] - 2026-08-05

- Update `lz4rip` crate dependency from 0.11.1 to 0.11.2.

## [0.1.1] - 2026-06-29

- Update `lz4rip` crate dependency from 0.8 to 0.9.

## [0.1.0] - 2026-06-20

- Initial release.
- `Lz4rip::FrameCodec`: frame-format LZ4 codec (Ractor-shareable).
- `Lz4rip::BlockCodec`: block-format LZ4 codec with reusable scratch table.
- `Lz4rip::Dictionary`: immutable value type for LZ4 dictionaries.
- `Lz4rip::DictTrainer`: COVER-based dictionary trainer.
- `Lz4rip.compress_bound`: maximum output size for a given input size.
