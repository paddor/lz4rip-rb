# frozen_string_literal: true

require_relative "test_helper"
require "objspace"

describe Lz4rip do
  it "version is a non empty string" do
    assert_instance_of String, Lz4rip::VERSION
    refute_empty Lz4rip::VERSION
  end
end


describe Lz4rip::FrameCodec, "without a dictionary" do
  before do
    @codec = Lz4rip::FrameCodec.new
  end


  it "round trips empty string" do
    ct = @codec.compress("")
    assert_equal "", @codec.decompress(ct)
  end


  it "round trips single byte" do
    ct = @codec.compress("x")
    assert_equal "x", @codec.decompress(ct)
  end


  it "round trips ascii text" do
    pt = "the quick brown fox jumps over the lazy dog"
    assert_equal pt, @codec.decompress(@codec.compress(pt))
  end


  it "round trips repetitive input and compresses" do
    pt = "A" * 100_000
    ct = @codec.compress(pt)
    assert_operator ct.bytesize, :<, pt.bytesize / 10
    assert_equal pt, @codec.decompress(ct)
  end


  it "round trips random bytes 1mib" do
    pt = Random.bytes(1_048_576)
    assert_equal pt, @codec.decompress(@codec.compress(pt))
  end


  it "round trips binary data with nul bytes" do
    pt = (0..255).map(&:chr).join * 16
    pt.force_encoding(Encoding::ASCII_8BIT)
    assert_equal pt, @codec.decompress(@codec.compress(pt))
  end


  it "emits lz4 frame magic" do
    ct = @codec.compress("anything")
    assert_equal [0x04, 0x22, 0x4D, 0x18], ct.bytes.first(4)
  end


  it "compress returns binary encoding" do
    ct = @codec.compress("hello")
    assert_equal Encoding::ASCII_8BIT, ct.encoding
  end


  it "decompress returns binary encoding" do
    pt = @codec.decompress(@codec.compress("hello"))
    assert_equal Encoding::ASCII_8BIT, pt.encoding
  end


  it "decompress allows exact max decompressed size" do
    pt = "frame limit payload " * 100
    ct = @codec.compress(pt)

    assert_equal pt, @codec.decompress(ct, max_decompressed_size: pt.bytesize)
  end


  it "decompress rejects over max decompressed size" do
    pt = "frame limit payload " * 100
    ct = @codec.compress(pt)

    err = assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(ct, max_decompressed_size: pt.bytesize - 1)
    end
    assert_match(/decompressed size limit exceeded/, err.message)
  end


  it "decompress limit applies to concatenated frames" do
    first = "A" * 1_000
    second = "B" * 1_000
    ct = @codec.compress(first) + @codec.compress(second)

    assert_equal first + second,
      @codec.decompress(ct, max_decompressed_size: first.bytesize + second.bytesize)

    assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(ct, max_decompressed_size: first.bytesize + second.bytesize - 1)
    end
  end


  it "raises decompress error on garbage" do
    assert_raises(Lz4rip::DecompressError) { @codec.decompress("not a valid lz4 frame") }
  end


  it "raises decompress error on truncated frame" do
    ct = @codec.compress("some data that will compress")
    assert_raises(Lz4rip::DecompressError) { @codec.decompress(ct[0, ct.bytesize / 2]) }
  end


  it "raises decompress error on empty input" do
    assert_raises(Lz4rip::DecompressError) { @codec.decompress("") }
  end


  it "decompress error is standard error subclass" do
    assert_includes Lz4rip::DecompressError.ancestors, StandardError
  end
end


describe "Lz4rip decompression limits" do
  it "no large output string on failed decompress" do
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


describe Lz4rip::Dictionary do
  before do
    @bytes = "header version=1 type=message field1="
  end


  it "stores bytes binary encoded and frozen" do
    d = Lz4rip::Dictionary.new(bytes: @bytes)
    assert_equal @bytes.b, d.bytes
    assert_predicate d.bytes, :frozen?
    assert_equal Encoding::ASCII_8BIT, d.bytes.encoding
  end


  it "defaults id to sha256 le" do
    expected = Digest::SHA256.digest(@bytes)[0, 4].unpack1("V")
    assert_equal expected, Lz4rip::Dictionary.new(bytes: @bytes).id
  end


  it "accepts caller supplied id" do
    d = Lz4rip::Dictionary.new(bytes: @bytes, id: 0xDEAD_BEEF)
    assert_equal 0xDEAD_BEEF, d.id
  end


  it "size reports dict size in bytes" do
    assert_equal @bytes.bytesize, Lz4rip::Dictionary.new(bytes: @bytes).size
  end


  it "immutability and value equality" do
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


  it "shareable across ractors" do
    require_ractor

    r = Ractor.new(Lz4rip::Dictionary.new(bytes: @bytes)) { |d| [d.bytes, d.id] }
    got_bytes, got_id = ractor_value(r)
    assert_equal @bytes.b, got_bytes
    assert_equal Digest::SHA256.digest(@bytes)[0, 4].unpack1("V"), got_id
  end
end


describe Lz4rip::FrameCodec, "with a dictionary" do
  before do
    @dict_bytes = "header version=1 type=message field1="
    @dict       = Lz4rip::Dictionary.new(bytes: @dict_bytes)
    @d          = Lz4rip::FrameCodec.new(dict: @dict)
    @no_dict    = Lz4rip::FrameCodec.new
  end


  it "no dict round trip" do
    msg = "the quick brown fox jumps over the lazy dog"
    ct  = @no_dict.compress(msg)
    assert_equal [0x04, 0x22, 0x4D, 0x18], ct.bytes.first(4)
    assert_equal msg, @no_dict.decompress(ct)
  end


  it "dict uses cached id" do
    assert_equal @dict.id, @d.id
  end


  it "string dict derives id" do
    c = Lz4rip::FrameCodec.new(dict: @dict_bytes)
    assert_equal @dict.id, c.id
  end


  it "raises type error for bad dict" do
    assert_raises(TypeError) { Lz4rip::FrameCodec.new(dict: 42) }
  end


  it "has dict reflects construction" do
    assert_predicate @d, :has_dict?
    refute_predicate @no_dict, :has_dict?
  end


  it "size is dict size or zero" do
    assert_equal @dict_bytes.bytesize, @d.size
    assert_equal 0, @no_dict.size
  end


  it "id is nil without dict" do
    assert_nil @no_dict.id
  end


  it "emits lz4 frame magic" do
    ct = @d.compress("header version=1 type=message field1=hello")
    assert_equal [0x04, 0x22, 0x4D, 0x18], ct.bytes.first(4)
  end


  it "raises on dict id mismatch" do
    d2 = Lz4rip::FrameCodec.new(dict: "totally different dictionary payload")
    ct = @d.compress("header version=1 type=message field1=hello")
    assert_raises(Lz4rip::DecompressError) { d2.decompress(ct) }
  end


  it "round trips message sharing dict prefix" do
    msg = "header version=1 type=message field1=hello world"
    ct  = @d.compress(msg)
    assert_equal msg, @d.decompress(ct)
  end


  it "round trips random bytes" do
    msg = Random.bytes(4096)
    assert_equal msg, @d.decompress(@d.compress(msg))
  end


  it "round trips empty string" do
    ct = @d.compress("")
    assert_equal "", @d.decompress(ct)
  end


  it "raises on garbage input" do
    assert_raises(Lz4rip::DecompressError) { @d.decompress("garbage") }
  end


  it "dict compresses better" do
    msg        = @dict_bytes + "payload"
    ct_with    = @d.compress(msg)
    ct_without = @no_dict.compress(msg)
    assert_operator ct_with.bytesize, :<, ct_without.bytesize
  end
end


describe "Lz4rip.compress_bound" do
  it "monotonic" do
    a = Lz4rip.compress_bound(100)
    b = Lz4rip.compress_bound(1_000)
    c = Lz4rip.compress_bound(1_000_000)
    assert_operator a, :<, b
    assert_operator b, :<, c
  end


  it "holds real output" do
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


describe Lz4rip::BlockCodec, "without a dictionary" do
  before do
    @codec = Lz4rip::BlockCodec.new
  end


  it "has dict is false" do
    refute_predicate @codec, :has_dict?
  end


  it "round trips empty string" do
    ct = @codec.compress("")
    assert_equal "", @codec.decompress(ct, decompressed_size: 0)
  end


  it "round trips ascii text" do
    pt = "the quick brown fox jumps over the lazy dog"
    ct = @codec.compress(pt)
    assert_equal pt, @codec.decompress(ct, decompressed_size: pt.bytesize)
  end


  it "round trips repetitive input and compresses" do
    pt = "A" * 100_000
    ct = @codec.compress(pt)
    assert_operator ct.bytesize, :<, pt.bytesize / 100
    assert_equal pt, @codec.decompress(ct, decompressed_size: pt.bytesize)
  end


  it "round trips across size buckets" do
    [0, 1, 12, 13, 64, 255, 256, 1024, 4096, 65_536, 1_048_576].each do |n|
      pt = Random.bytes(n)
      ct = @codec.compress(pt)
      assert_equal pt, @codec.decompress(ct, decompressed_size: n),
        "round-trip failed at size #{n}"
    end
  end


  it "emits binary encoded output" do
    ct = @codec.compress("hello")
    assert_equal Encoding::ASCII_8BIT, ct.encoding
  end


  it "reuses scratch table" do
    500.times do |i|
      pt = "message #{i} " * (1 + i % 10)
      ct = @codec.compress(pt)
      assert_equal pt, @codec.decompress(ct, decompressed_size: pt.bytesize)
    end
  end


  it "size is zero" do
    assert_equal 0, @codec.size
  end
end


describe Lz4rip::BlockCodec, "with a dictionary" do
  before do
    @dict  = "JSON field prefix: version=1 type=event data="
    @codec = Lz4rip::BlockCodec.new(dict: @dict)
  end


  it "has dict is true" do
    assert_predicate @codec, :has_dict?
  end


  it "round trips" do
    msg = "JSON field prefix: version=1 type=event data=hello"
    ct  = @codec.compress(msg)
    assert_equal msg, @codec.decompress(ct, decompressed_size: msg.bytesize)
  end


  it "decodes with separate receiver" do
    msg = "JSON field prefix: version=1 type=event data=world"
    ct  = @codec.compress(msg)
    receiver = Lz4rip::BlockCodec.new(dict: @dict)
    assert_equal msg, receiver.decompress(ct, decompressed_size: msg.bytesize)
  end


  it "dict compresses better" do
    msg        = "JSON field prefix: version=1 type=event data=x"
    ct_with    = @codec.compress(msg)
    ct_without = Lz4rip::BlockCodec.new.compress(msg)
    assert_operator ct_with.bytesize, :<, ct_without.bytesize
  end


  it "round trips across size buckets" do
    [0, 1, 64, 1024, 65_536].each do |n|
      pt = Random.bytes(n)
      ct = @codec.compress(pt)
      assert_equal pt, @codec.decompress(ct, decompressed_size: n),
        "round-trip failed at size #{n}"
    end
  end


  it "round trips 500 times" do
    msgs = 500.times.map { |i| "JSON field prefix: version=1 type=event data=#{i}" }
    ciphertexts = msgs.map { |m| @codec.compress(m) }
    msgs.zip(ciphertexts).each do |msg, ct|
      assert_equal msg, @codec.decompress(ct, decompressed_size: msg.bytesize)
    end
  end


  it "size is stream plus dict" do
    assert_equal Lz4rip.block_stream_size + @dict.bytesize, @codec.size
  end
end


describe Lz4rip::BlockCodec, "bounded decompression" do
  before do
    @codec = Lz4rip::BlockCodec.new
  end


  it "refuses to write past decompressed size" do
    pt = "X" * 10_000
    ct = @codec.compress(pt)
    assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(ct, decompressed_size: 100)
    end
  end


  it "raises on garbage input" do
    malformed = "\xFF".b
    assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(malformed, decompressed_size: 100)
    end
  end


  it "raises on truncated ciphertext" do
    pt = "X" * 10_000
    ct = @codec.compress(pt)
    assert_raises(Lz4rip::DecompressError) do
      @codec.decompress(ct[0, ct.bytesize / 2], decompressed_size: pt.bytesize)
    end
  end


  it "fuzz random inputs" do
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


  it "fuzz mutated valid ciphertexts" do
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


describe Lz4rip::BlockCodec, "with the wrong dictionary" do
  before do
    @dict_a = ("header version=1 type=message field=" * 3).b
    @dict_b = ("totally different dictionary payload here " * 3).b
  end


  it "does not crash with wrong dict" do
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


  it "does not crash without dict" do
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


describe Lz4rip::DictTrainer do
  def json_msg(i)
    %Q({"ts":"2026-04-27T12:00:00.#{format("%04d", i)}Z","level":"INFO","service":"api-gw","trace":"#{format("%08x", i)}","method":"GET","path":"/v1/users/#{format("%04d", i)}","status":200,"latency_ms":#{10 + i % 490},"region":"us-east-1"})
  end


  it "caps max dict size at 65535" do
    t = Lz4rip::DictTrainer.new(100_000)
    assert_equal 65535, t.max_dict_size
  end


  it "starts with zero samples" do
    t = Lz4rip::DictTrainer.new(2048)
    assert_equal 0, t.sample_count
    assert_equal 0, t.total_bytes
    refute_predicate t, :trained?
  end


  it "sample coercion can call back into trainer" do
    trainer = Lz4rip::DictTrainer.new(2048)
    sample = Object.new
    sample.define_singleton_method(:to_str) do
      trainer.sample_count
      "training sample"
    end

    assert_nil trainer.add_sample(sample)
    assert_equal 1, trainer.sample_count
    assert_equal 15, trainer.total_bytes
  end


  it "sample coercion preserves throw" do
    trainer = Lz4rip::DictTrainer.new(2048)
    sample = Object.new
    sample.define_singleton_method(:to_str) { throw :sample, :escaped }

    assert_equal :escaped, catch(:sample) { trainer.add_sample(sample) }
    assert_equal 0, trainer.sample_count
    assert_nil trainer.add_sample("usable sample")
  end


  it "sample coercion can consume trainer" do
    trainer = Lz4rip::DictTrainer.new(2048)
    sample = Object.new
    sample.define_singleton_method(:to_str) do
      trainer.train
      "training sample"
    end

    assert_raises(RuntimeError) { trainer.add_sample(sample) }
    assert_predicate trainer, :trained?
  end


  it "trains nonempty dict from 100 json samples" do
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


  it "trained dict improves block codec compression" do
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


  it "returns empty dict with fewer than 2 samples" do
    t = Lz4rip::DictTrainer.new(2048)
    t.add_sample("hello world")
    assert_equal "", t.train
  end


  it "skips samples shorter than 4 bytes" do
    t = Lz4rip::DictTrainer.new(2048)
    t.add_sample("hi")
    assert_equal 0, t.sample_count
  end


  it "truncates oversized samples" do
    t = Lz4rip::DictTrainer.new(64)
    t.add_sample("x" * 200)
    assert_equal 1, t.sample_count
  end


  it "evicts old samples when budget exceeded" do
    t = Lz4rip::DictTrainer.new(2048)
    200.times { |i| t.add_sample(json_msg(i)) }
    assert_operator t.total_bytes, :<=, 2048 * 8
    assert_operator t.sample_count, :<, 200
  end


  it "raises runtime error on double train" do
    t = Lz4rip::DictTrainer.new(2048)
    10.times { |i| t.add_sample(json_msg(i)) }
    t.train
    assert_raises(RuntimeError) { t.train }
  end


  it "raises runtime error on add sample after train" do
    t = Lz4rip::DictTrainer.new(2048)
    t.add_sample("hello world")
    t.train
    assert_raises(RuntimeError) { t.add_sample("more data") }
  end


  it "raises runtime error on sample count after train" do
    t = Lz4rip::DictTrainer.new(2048)
    t.train
    assert_raises(RuntimeError) { t.sample_count }
  end


  it "raises runtime error on total bytes after train" do
    t = Lz4rip::DictTrainer.new(2048)
    t.train
    assert_raises(RuntimeError) { t.total_bytes }
  end


  it "cannot cross ractor boundaries" do
    require_ractor

    t = Lz4rip::DictTrainer.new(2048)
    assert_raises(TypeError, Ractor::IsolationError) do
      Ractor.new(t) { |tr| tr.add_sample("data") }
    end
  end
end


describe "Lz4rip Ractor safety" do
  before do
    require_ractor
  end


  it "compress decompress inside ractor" do
    r = Ractor.new do
      codec = Lz4rip::FrameCodec.new
      pt    = "hello from inside a ractor " * 100
      ct    = codec.compress(pt)
      [ct.bytesize, codec.decompress(ct) == pt]
    end
    size, ok = ractor_value(r)
    assert_equal true, ok
    assert_operator size, :>, 0
  end


  it "frame codec with dict is ractor shareable" do
    bytes = +"shared dict prefix "
    codec = Lz4rip::FrameCodec.new(dict: bytes)
    refute_predicate bytes, :frozen?
    bytes.replace("changed")
    assert Ractor.shareable?(codec)
    r = Ractor.new(codec) do |shared|
      input = "shared dict prefix body"
      shared.decompress(shared.compress(input)) == input
    end
    assert_equal true, ractor_value(r)
  end


  it "shares one frame codec across ractors" do
    codec = Lz4rip::FrameCodec.new
    assert_predicate codec, :frozen?
    assert Ractor.shareable?(codec)
    ractors = 4.times.map do |i|
      Ractor.new(codec, i) do |shared, index|
        input = "shared payload #{index} " * 20_000
        10.times do
          raise "round trip mismatch" unless shared.decompress(shared.compress(input)) == input
        end
        :ok
      end
    end
    assert_equal [:ok] * 4, ractors.map { |ractor| ractor_value(ractor) }
  end


  it "block codec is per ractor" do
    r = Ractor.new do
      c   = Lz4rip::BlockCodec.new
      msg = "ractor local payload " * 50
      ct  = c.compress(msg)
      c.decompress(ct, decompressed_size: msg.bytesize) == msg
    end
    assert_equal true, ractor_value(r)
  end


  it "block codec cannot cross ractor boundaries" do
    codec = Lz4rip::BlockCodec.new
    assert_raises(TypeError, Ractor::IsolationError) do
      Ractor.new(codec) { |c| c.compress("payload") }
    end
  end


  it "multiple ractors compress in parallel" do
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
    results = ractors.map { |r| ractor_value(r) }
    assert_equal [:ok, :ok, :ok, :ok], results
  end
end


describe "Lz4rip native interruptions" do
  it "interrupted compression unlocks input and releases codec" do
    interrupted_error = Class.new(StandardError)
    skip "requires MRI GVL" unless RUBY_ENGINE == "ruby"

    codecs = [Lz4rip::FrameCodec.new, Lz4rip::BlockCodec.new, Lz4rip::BlockCodec.new(dict: "dictionary")]
    codecs.each do |codec|
      input = Random.bytes(64 * 1024 * 1024)
      worker = Thread.new do
        codec.compress(input)
      rescue interrupted_error => error
        error
      end
      worker.report_on_exception = false

      begin
        assert wait_for_input_lock(input, worker), "compression did not lock input"
        worker.raise(interrupted_error)
        assert_instance_of interrupted_error, worker.value
        input.replace("usable")
        assert_equal "usable", input
        assert_equal input, decompress(codec, codec.compress(input), input.bytesize)
      ensure
        worker.kill if worker.alive?
        worker.join
      end
    end
  end


  it "killed compression unlocks input" do
    skip "requires MRI GVL" unless RUBY_ENGINE == "ruby"

    codec = Lz4rip::FrameCodec.new
    input = Random.bytes(64 * 1024 * 1024)
    worker = Thread.new { codec.compress(input) }
    worker.report_on_exception = false
    begin
      assert wait_for_input_lock(input, worker), "compression did not lock input"
      worker.kill
      assert_nil worker.value
      input.replace("usable")
      assert_equal "usable", input
    ensure
      worker.kill if worker.alive?
      worker.join
    end
  end


  it "contended small compression locks input" do
    skip "requires MRI GVL" unless RUBY_ENGINE == "ruby"

    codec = Lz4rip::BlockCodec.new(dict: "dictionary")
    large_input = Random.bytes(128 * 1024 * 1024)
    small_input = +"small mutable input"
    large_worker = Thread.new { codec.compress(large_input) }
    small_worker = nil

    begin
      assert wait_for_input_lock(large_input, large_worker), "large compression did not lock input"
      small_worker = Thread.new { codec.compress(small_input) }
      assert wait_for_input_lock(small_input, small_worker), "contended small input was not locked"
      assert_raises(RuntimeError) { small_input.replace("changed") }
      small_compressed = small_worker.value
      large_worker.value
      assert_equal small_input, decompress(codec, small_compressed, small_input.bytesize)
      small_input.replace("usable")
      assert_equal "usable", small_input
    ensure
      [small_worker, large_worker].compact.each do |worker|
        worker.kill if worker.alive?
        worker.join
      end
    end
  end

  private

  def decompress(codec, compressed, size)
    codec.is_a?(Lz4rip::BlockCodec) ? codec.decompress(compressed, decompressed_size: size) : codec.decompress(compressed)
  end

  def wait_for_input_lock(input, worker)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while worker.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        input.setbyte(0, input.getbyte(0))
      rescue RuntimeError
        return true
      end
      Thread.pass
    end
    false
  end
end


describe "Lz4rip native coercion" do
  it "decompression borrows input after size coercion" do
    [Lz4rip::FrameCodec.new, Lz4rip::BlockCodec.new].each do |codec|
      input = codec.compress("old")
      expected = "replacement payload " * 500
      size = Object.new
      size.define_singleton_method(:to_int) do
        input.replace(codec.compress(expected))
        expected.bytesize
      end

      actual = codec._decompress(input, size)
      assert_equal expected, actual
    end
  end
end
