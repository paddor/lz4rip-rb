# frozen_string_literal: true

require_relative "test_helper"
require "objspace"

class TestVersion < Minitest::Test
  def test_version_is_a_non_empty_string
    assert_instance_of String, Lz4rip::VERSION
    refute_empty Lz4rip::VERSION
  end
end


class TestFrameCodecNoDict < Minitest::Test
  def setup
    @codec = Lz4rip::FrameCodec.new
  end


  def test_round_trips_empty_string
    ct = @codec.compress("")
    assert_equal "", @codec.decompress(ct)
  end


  def test_round_trips_single_byte
    ct = @codec.compress("x")
    assert_equal "x", @codec.decompress(ct)
  end


  def test_round_trips_ascii_text
    pt = "the quick brown fox jumps over the lazy dog"
    assert_equal pt, @codec.decompress(@codec.compress(pt))
  end


  def test_round_trips_repetitive_input_and_compresses
    pt = "A" * 100_000
    ct = @codec.compress(pt)
    assert_operator ct.bytesize, :<, pt.bytesize / 10
    assert_equal pt, @codec.decompress(ct)
  end


  def test_round_trips_random_bytes_1mib
    pt = Random.bytes(1_048_576)
    assert_equal pt, @codec.decompress(@codec.compress(pt))
  end


  def test_round_trips_binary_data_with_nul_bytes
    pt = (0..255).map(&:chr).join * 16
    pt.force_encoding(Encoding::ASCII_8BIT)
    assert_equal pt, @codec.decompress(@codec.compress(pt))
  end


  def test_emits_lz4_frame_magic
    ct = @codec.compress("anything")
    assert_equal [0x04, 0x22, 0x4D, 0x18], ct.bytes.first(4)
  end


  def test_compress_returns_binary_encoding
    ct = @codec.compress("hello")
    assert_equal Encoding::ASCII_8BIT, ct.encoding
  end


  def test_decompress_returns_binary_encoding
    pt = @codec.decompress(@codec.compress("hello"))
    assert_equal Encoding::ASCII_8BIT, pt.encoding
  end


  def test_raises_decompress_error_on_garbage
    assert_raises(Lz4rip::DecompressError) { @codec.decompress("not a valid lz4 frame") }
  end


  def test_raises_decompress_error_on_truncated_frame
    ct = @codec.compress("some data that will compress")
    assert_raises(Lz4rip::DecompressError) { @codec.decompress(ct[0, ct.bytesize / 2]) }
  end


  def test_raises_decompress_error_on_empty_input
    assert_raises(Lz4rip::DecompressError) { @codec.decompress("") }
  end


  def test_decompress_error_is_standard_error_subclass
    assert_includes Lz4rip::DecompressError.ancestors, StandardError
  end
end


class TestDosResistance < Minitest::Test
  def test_no_large_output_string_on_failed_decompress
    codec   = Lz4rip::FrameCodec.new
    size    = 1_048_576
    garbage = "\x00".b * size

    GC.start
    before = ObjectSpace.each_object(String).count { |s| s.bytesize >= size }

    10.times do
      assert_raises(Lz4rip::DecompressError) { codec.decompress(garbage) }
    end

    GC.start
    after = ObjectSpace.each_object(String).count { |s| s.bytesize >= size }

    assert_equal before, after,
      "failed decompress should not leak large output strings"
  end
end


class TestDictionary < Minitest::Test
  def setup
    @bytes = "header version=1 type=message field1="
  end


  def test_stores_bytes_binary_encoded_and_frozen
    d = Lz4rip::Dictionary.new(bytes: @bytes)
    assert_equal @bytes.b, d.bytes
    assert_predicate d.bytes, :frozen?
    assert_equal Encoding::ASCII_8BIT, d.bytes.encoding
  end


  def test_defaults_id_to_sha256_le
    expected = Digest::SHA256.digest(@bytes)[0, 4].unpack1("V")
    assert_equal expected, Lz4rip::Dictionary.new(bytes: @bytes).id
  end


  def test_accepts_caller_supplied_id
    d = Lz4rip::Dictionary.new(bytes: @bytes, id: 0xDEAD_BEEF)
    assert_equal 0xDEAD_BEEF, d.id
  end


  def test_size_reports_dict_size_in_bytes
    assert_equal @bytes.bytesize, Lz4rip::Dictionary.new(bytes: @bytes).size
  end


  def test_immutability_and_value_equality
    assert_predicate Lz4rip::Dictionary.new(bytes: @bytes), :frozen?
    assert_equal(
      Lz4rip::Dictionary.new(bytes: @bytes),
      Lz4rip::Dictionary.new(bytes: @bytes.dup),
    )
    assert_equal(
      Lz4rip::Dictionary.new(bytes: @bytes).hash,
      Lz4rip::Dictionary.new(bytes: @bytes.dup).hash,
    )
  end


  def test_shareable_across_ractors
    r = Ractor.new(Lz4rip::Dictionary.new(bytes: @bytes)) { |d| [d.bytes, d.id] }
    got_bytes, got_id = r.value
    assert_equal @bytes.b, got_bytes
    assert_equal Digest::SHA256.digest(@bytes)[0, 4].unpack1("V"), got_id
  end
end


class TestFrameCodecWithDict < Minitest::Test
  def setup
    @dict_bytes = "header version=1 type=message field1="
    @dict       = Lz4rip::Dictionary.new(bytes: @dict_bytes)
    @d          = Lz4rip::FrameCodec.new(dict: @dict)
    @no_dict    = Lz4rip::FrameCodec.new
  end


  def test_no_dict_round_trip
    msg = "the quick brown fox jumps over the lazy dog"
    ct  = @no_dict.compress(msg)
    assert_equal [0x04, 0x22, 0x4D, 0x18], ct.bytes.first(4)
    assert_equal msg, @no_dict.decompress(ct)
  end


  def test_dict_uses_cached_id
    assert_equal @dict.id, @d.id
  end


  def test_string_dict_derives_id
    c = Lz4rip::FrameCodec.new(dict: @dict_bytes)
    assert_equal @dict.id, c.id
  end


  def test_raises_type_error_for_bad_dict
    assert_raises(TypeError) { Lz4rip::FrameCodec.new(dict: 42) }
  end


  def test_has_dict_reflects_construction
    assert_predicate @d, :has_dict?
    refute_predicate @no_dict, :has_dict?
  end


  def test_size_is_dict_size_or_zero
    assert_equal @dict_bytes.bytesize, @d.size
    assert_equal 0, @no_dict.size
  end


  def test_id_is_nil_without_dict
    assert_nil @no_dict.id
  end


  def test_emits_lz4_frame_magic
    ct = @d.compress("header version=1 type=message field1=hello")
    assert_equal [0x04, 0x22, 0x4D, 0x18], ct.bytes.first(4)
  end


  def test_raises_on_dict_id_mismatch
    d2 = Lz4rip::FrameCodec.new(dict: "totally different dictionary payload")
    ct = @d.compress("header version=1 type=message field1=hello")
    assert_raises(Lz4rip::DecompressError) { d2.decompress(ct) }
  end


  def test_round_trips_message_sharing_dict_prefix
    msg = "header version=1 type=message field1=hello world"
    ct  = @d.compress(msg)
    assert_equal msg, @d.decompress(ct)
  end


  def test_round_trips_random_bytes
    msg = Random.bytes(4096)
    assert_equal msg, @d.decompress(@d.compress(msg))
  end


  def test_round_trips_empty_string
    ct = @d.compress("")
    assert_equal "", @d.decompress(ct)
  end


  def test_raises_on_garbage_input
    assert_raises(Lz4rip::DecompressError) { @d.decompress("garbage") }
  end


  def test_dict_compresses_better
    msg        = @dict_bytes + "payload"
    ct_with    = @d.compress(msg)
    ct_without = @no_dict.compress(msg)
    assert_operator ct_with.bytesize, :<, ct_without.bytesize
  end
end


class TestCompressBound < Minitest::Test
  def test_monotonic
    a = Lz4rip.compress_bound(100)
    b = Lz4rip.compress_bound(1_000)
    c = Lz4rip.compress_bound(1_000_000)
    assert_operator a, :<, b
    assert_operator b, :<, c
  end


  def test_holds_real_output
    codec = Lz4rip::BlockCodec.new
    [0, 1, 100, 4096, 100_000].each do |n|
      pt    = Random.bytes(n)
      bound = Lz4rip.compress_bound(n)
      ct    = codec.compress(pt)
      assert_operator ct.bytesize, :<=, bound,
        "compress_bound(#{n}) = #{bound} must hold #{ct.bytesize} bytes of ciphertext"
    end
  end
end


class TestBlockCodecNoDict < Minitest::Test
  def setup
    @codec = Lz4rip::BlockCodec.new
  end


  def test_has_dict_is_false
    refute_predicate @codec, :has_dict?
  end


  def test_round_trips_empty_string
    ct = @codec.compress("")
    assert_equal "", @codec.decompress(ct, decompressed_size: 0)
  end


  def test_round_trips_ascii_text
    pt = "the quick brown fox jumps over the lazy dog"
    ct = @codec.compress(pt)
    assert_equal pt, @codec.decompress(ct, decompressed_size: pt.bytesize)
  end


  def test_round_trips_repetitive_input_and_compresses
    pt = "A" * 100_000
    ct = @codec.compress(pt)
    assert_operator ct.bytesize, :<, pt.bytesize / 100
    assert_equal pt, @codec.decompress(ct, decompressed_size: pt.bytesize)
  end


  def test_round_trips_across_size_buckets
    [0, 1, 12, 13, 64, 255, 256, 1024, 4096, 65_536, 1_048_576].each do |n|
      pt = Random.bytes(n)
      ct = @codec.compress(pt)
      assert_equal pt, @codec.decompress(ct, decompressed_size: n),
        "round-trip failed at size #{n}"
    end
  end


  def test_emits_binary_encoded_output
    ct = @codec.compress("hello")
    assert_equal Encoding::ASCII_8BIT, ct.encoding
  end


  def test_reuses_scratch_table
    500.times do |i|
      pt = "message #{i} " * (1 + i % 10)
      ct = @codec.compress(pt)
      assert_equal pt, @codec.decompress(ct, decompressed_size: pt.bytesize)
    end
  end


  def test_size_is_zero
    assert_equal 0, @codec.size
  end
end


class TestBlockCodecWithDict < Minitest::Test
  def setup
    @dict  = "JSON field prefix: version=1 type=event data="
    @codec = Lz4rip::BlockCodec.new(dict: @dict)
  end


  def test_has_dict_is_true
    assert_predicate @codec, :has_dict?
  end


  def test_round_trips
    msg = "JSON field prefix: version=1 type=event data=hello"
    ct  = @codec.compress(msg)
    assert_equal msg, @codec.decompress(ct, decompressed_size: msg.bytesize)
  end


  def test_decodes_with_separate_receiver
    msg = "JSON field prefix: version=1 type=event data=world"
    ct  = @codec.compress(msg)
    receiver = Lz4rip::BlockCodec.new(dict: @dict)
    assert_equal msg, receiver.decompress(ct, decompressed_size: msg.bytesize)
  end


  def test_dict_compresses_better
    msg        = "JSON field prefix: version=1 type=event data=x"
    ct_with    = @codec.compress(msg)
    ct_without = Lz4rip::BlockCodec.new.compress(msg)
    assert_operator ct_with.bytesize, :<, ct_without.bytesize
  end


  def test_round_trips_across_size_buckets
    [0, 1, 64, 1024, 65_536].each do |n|
      pt = Random.bytes(n)
      ct = @codec.compress(pt)
      assert_equal pt, @codec.decompress(ct, decompressed_size: n),
        "round-trip failed at size #{n}"
    end
  end


  def test_round_trips_500_times
    msgs = 500.times.map { |i| "JSON field prefix: version=1 type=event data=#{i}" }
    ciphertexts = msgs.map { |m| @codec.compress(m) }
    msgs.zip(ciphertexts).each do |msg, ct|
      assert_equal msg, @codec.decompress(ct, decompressed_size: msg.bytesize)
    end
  end


  def test_size_is_stream_plus_dict
    assert_equal Lz4rip.block_stream_size + @dict.bytesize, @codec.size
  end
end


class TestBoundedDecompression < Minitest::Test
  def setup
    @codec = Lz4rip::BlockCodec.new
  end


  def test_refuses_to_write_past_decompressed_size
    pt = "X" * 10_000
    ct = @codec.compress(pt)
    assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(ct, decompressed_size: 100)
    end
  end


  def test_raises_on_garbage_input
    malformed = "\xFF".b
    assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(malformed, decompressed_size: 100)
    end
  end


  def test_raises_on_truncated_ciphertext
    pt = "X" * 10_000
    ct = @codec.compress(pt)
    assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(ct[0, ct.bytesize / 2], decompressed_size: pt.bytesize)
    end
  end


  def test_fuzz_random_inputs
    srand(0xC0DEC)
    10_000.times do
      len = rand(1..1024)
      blob = Random.bytes(len)
      decompressed_size = rand(0..16_384)
      begin
        @codec.decompress(blob, decompressed_size: decompressed_size)
      rescue Lz4rip::DecompressError
        # expected
      end
    end
  end


  def test_fuzz_mutated_valid_ciphertexts
    srand(0xFA11B1)
    pt = "the quick brown fox jumps over the lazy dog " * 64
    valid = @codec.compress(pt)
    10_000.times do
      mutated = valid.dup
      1.upto(rand(1..3)) do
        i = rand(mutated.bytesize)
        mutated.setbyte(i, rand(256))
      end
      begin
        @codec.decompress(mutated, decompressed_size: pt.bytesize)
      rescue Lz4rip::DecompressError
        # expected for most mutations
      end
    end
  end
end


class TestWrongDictDecode < Minitest::Test
  def setup
    @dict_a = ("header version=1 type=message field=" * 3).b
    @dict_b = ("totally different dictionary payload here " * 3).b
  end


  def test_does_not_crash_with_wrong_dict
    sender   = Lz4rip::BlockCodec.new(dict: @dict_a)
    receiver = Lz4rip::BlockCodec.new(dict: @dict_b)
    msg = "header version=1 type=message field=hello"
    ct  = sender.compress(msg)

    begin
      out = receiver.decompress(ct, decompressed_size: msg.bytesize)
      refute_equal msg, out
    rescue Lz4rip::DecompressError
      # also fine
    end
  end


  def test_does_not_crash_without_dict
    sender   = Lz4rip::BlockCodec.new(dict: @dict_a)
    receiver = Lz4rip::BlockCodec.new
    msg = "header version=1 type=message field=hello"
    ct  = sender.compress(msg)

    begin
      out = receiver.decompress(ct, decompressed_size: msg.bytesize)
      refute_equal msg, out
    rescue Lz4rip::DecompressError
      # also fine
    end
  end
end


class TestDictTrainer < Minitest::Test
  def json_msg(i)
    %Q({"ts":"2026-04-27T12:00:00.#{format("%04d", i)}Z","level":"INFO","service":"api-gw","trace":"#{format("%08x", i)}","method":"GET","path":"/v1/users/#{format("%04d", i)}","status":200,"latency_ms":#{10 + i % 490},"region":"us-east-1"})
  end


  def test_caps_max_dict_size_at_65535
    t = Lz4rip::DictTrainer.new(100_000)
    assert_equal 65535, t.max_dict_size
  end


  def test_starts_with_zero_samples
    t = Lz4rip::DictTrainer.new(2048)
    assert_equal 0, t.sample_count
    assert_equal 0, t.total_bytes
    refute_predicate t, :trained?
  end


  def test_trains_nonempty_dict_from_100_json_samples
    t = Lz4rip::DictTrainer.new(2048)
    100.times { |i| t.add_sample(json_msg(i)) }
    assert_operator t.sample_count, :>, 0
    assert_operator t.total_bytes, :>, 0

    dict = t.train
    assert_predicate t, :trained?
    refute_empty dict
    assert_operator dict.bytesize, :<=, 2048
    assert_equal Encoding::ASCII_8BIT, dict.encoding
  end


  def test_trained_dict_improves_block_codec_compression
    t = Lz4rip::DictTrainer.new(2048)
    200.times { |i| t.add_sample(json_msg(i)) }
    dict = t.train

    codec    = Lz4rip::BlockCodec.new(dict: dict)
    no_dict  = Lz4rip::BlockCodec.new
    msg      = json_msg(9999)
    ct_with  = codec.compress(msg)
    ct_plain = no_dict.compress(msg)
    assert_operator ct_with.bytesize, :<, ct_plain.bytesize
    assert_equal msg, codec.decompress(ct_with, decompressed_size: msg.bytesize)
  end


  def test_returns_empty_dict_with_fewer_than_2_samples
    t = Lz4rip::DictTrainer.new(2048)
    t.add_sample("hello world")
    assert_equal "", t.train
  end


  def test_skips_samples_shorter_than_4_bytes
    t = Lz4rip::DictTrainer.new(2048)
    t.add_sample("hi")
    assert_equal 0, t.sample_count
  end


  def test_truncates_oversized_samples
    t = Lz4rip::DictTrainer.new(64)
    t.add_sample("x" * 200)
    assert_equal 1, t.sample_count
  end


  def test_evicts_old_samples_when_budget_exceeded
    t = Lz4rip::DictTrainer.new(2048)
    200.times { |i| t.add_sample(json_msg(i)) }
    assert_operator t.total_bytes, :<=, 2048 * 8
    assert_operator t.sample_count, :<, 200
  end


  def test_raises_runtime_error_on_double_train
    t = Lz4rip::DictTrainer.new(2048)
    10.times { |i| t.add_sample(json_msg(i)) }
    t.train
    assert_raises(RuntimeError) { t.train }
  end


  def test_raises_runtime_error_on_add_sample_after_train
    t = Lz4rip::DictTrainer.new(2048)
    t.add_sample("hello world")
    t.train
    assert_raises(RuntimeError) { t.add_sample("more data") }
  end


  def test_raises_runtime_error_on_sample_count_after_train
    t = Lz4rip::DictTrainer.new(2048)
    t.train
    assert_raises(RuntimeError) { t.sample_count }
  end


  def test_raises_runtime_error_on_total_bytes_after_train
    t = Lz4rip::DictTrainer.new(2048)
    t.train
    assert_raises(RuntimeError) { t.total_bytes }
  end


  def test_cannot_cross_ractor_boundaries
    t = Lz4rip::DictTrainer.new(2048)
    assert_raises(TypeError, Ractor::IsolationError) do
      Ractor.new(t) { |tr| tr.add_sample("data") }
    end
  end
end


class TestRactorSafety < Minitest::Test
  def test_compress_decompress_inside_ractor
    r = Ractor.new do
      codec = Lz4rip::FrameCodec.new
      pt    = "hello from inside a ractor " * 100
      ct    = codec.compress(pt)
      [ct.bytesize, codec.decompress(ct) == pt]
    end
    size, ok = r.value
    assert_equal true, ok
    assert_operator size, :>, 0
  end


  def test_frame_codec_is_ractor_shareable
    r = Ractor.new do
      d   = Lz4rip::FrameCodec.new(dict: "shared dict prefix ")
      msg = "shared dict prefix body"
      ct  = d.compress(msg)
      d.decompress(ct) == msg
    end
    assert_equal true, r.value
  end


  def test_block_codec_is_per_ractor
    r = Ractor.new do
      c   = Lz4rip::BlockCodec.new
      msg = "ractor local payload " * 50
      ct  = c.compress(msg)
      c.decompress(ct, decompressed_size: msg.bytesize) == msg
    end
    assert_equal true, r.value
  end


  def test_block_codec_cannot_cross_ractor_boundaries
    codec = Lz4rip::BlockCodec.new
    assert_raises(TypeError, Ractor::IsolationError) do
      Ractor.new(codec) { |c| c.compress("payload") }
    end
  end


  def test_multiple_ractors_compress_in_parallel
    ractors = 4.times.map do |i|
      Ractor.new(i) do |idx|
        codec = Lz4rip::FrameCodec.new
        pt    = "ractor #{idx} payload " * 1000
        1000.times do
          ct = codec.compress(pt)
          raise "mismatch in ractor #{idx}" unless codec.decompress(ct) == pt
        end
        :ok
      end
    end
    results = ractors.map(&:value)
    assert_equal [:ok, :ok, :ok, :ok], results
  end
end
