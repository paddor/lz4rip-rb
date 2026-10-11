# Changelog

## [Unreleased]

## [0.2.1] - 2026-10-11

- Update the `lz4rip` crate dependency to 0.11.10 and `rb-sys` to 0.9.130.
- Make `FrameCodec` instances Ractor-shareable as documented, with native
  dictionary copies that leave caller strings mutable.
- Unlock input strings and free native results when Ruby interrupts a call
  that released the GVL.
- Protect mutable inputs when mutex contention releases the GVL, including
  calls below the normal size threshold.
- Catch Rust panics inside native callbacks instead of aborting the process.
- Preserve Ruby exceptions, `Thread#kill`, and `catch`/`throw` through
  protected native calls.
- Avoid trainer deadlocks during sample coercion and borrow decompression
  input after size coercion.
- Update GitHub Actions checkout to v7 and check Rust tests, formatting, and
  Clippy in CI.

## [0.2.0] - 2026-08-07

- Release the Ruby GVL around large frame/block compression and frame
  decompression calls.
- Update the `lz4rip` crate dependency to 0.11.3.
- Replace Magnus with direct `rb-sys` bindings, add TruffleRuby build support,
  and lower the Ruby requirement to 3.4.
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
