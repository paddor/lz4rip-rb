use magnus::{
    exception::ExceptionClass, function, method, prelude::*, r_string::RString, rb_sys::AsRawValue,
    value::Opaque, Error, Ruby,
};
use std::cell::RefCell;
use std::ffi::c_void;
use std::io::{Cursor, Read, Write};
use std::mem::MaybeUninit;
use std::ptr;
use std::sync::OnceLock;

use lz4::block::{self, Decompressor, DictCompressor, DictTrainer};
use lz4::frame::{BlockMode, FrameDecoder, FrameEncoder, FrameInfo};

const COMPRESSOR_HEAP_SIZE: usize = 8192;

const LZ4_FRAME_MAGIC: [u8; 4] = [0x04, 0x22, 0x4d, 0x18];
const GVL_COMPRESS_THRESHOLD: usize = 256 * 1024;
const GVL_FRAME_DECOMPRESS_THRESHOLD: usize = 256 * 1024;

static DECOMPRESS_ERROR: OnceLock<Opaque<ExceptionClass>> = OnceLock::new();

type RbWithoutGvlFunc = unsafe extern "C" fn(*mut c_void) -> *mut c_void;
type RbUnblockFunc = unsafe extern "C" fn(*mut c_void);

unsafe extern "C" {
    fn rb_thread_call_without_gvl(
        func: Option<RbWithoutGvlFunc>,
        data1: *mut c_void,
        ubf: Option<RbUnblockFunc>,
        data2: *mut c_void,
    ) -> *mut c_void;
    fn rb_str_locktmp(str: rb_sys::VALUE) -> rb_sys::VALUE;
    fn rb_str_unlocktmp(str: rb_sys::VALUE) -> rb_sys::VALUE;
}

fn should_release_compress_gvl(input_len: usize) -> bool {
    input_len >= GVL_COMPRESS_THRESHOLD
}

fn should_release_frame_decompress_gvl(input_len: usize) -> bool {
    input_len >= GVL_FRAME_DECOMPRESS_THRESHOLD
}

struct WithoutGvlData<F, R> {
    func: Option<F>,
    output: MaybeUninit<R>,
}

unsafe extern "C" fn without_gvl_trampoline<F, R>(data: *mut c_void) -> *mut c_void
where
    F: FnOnce() -> R,
{
    let data = unsafe { &mut *(data.cast::<WithoutGvlData<F, R>>()) };
    let func = data.func.take().expect("missing without-GVL function");
    data.output.write(func());
    ptr::null_mut()
}

fn without_gvl<F, R>(func: F) -> R
where
    F: FnOnce() -> R,
{
    let mut data = WithoutGvlData {
        func: Some(func),
        output: MaybeUninit::uninit(),
    };
    unsafe {
        rb_thread_call_without_gvl(
            Some(without_gvl_trampoline::<F, R>),
            (&mut data as *mut WithoutGvlData<F, R>).cast::<c_void>(),
            None,
            ptr::null_mut(),
        );
        data.output.assume_init()
    }
}

struct RStringLock {
    raw: rb_sys::VALUE,
    locked: bool,
}

impl RStringLock {
    fn new(s: RString) -> Self {
        let locked = !s.is_frozen();
        let raw = s.as_raw();
        if locked {
            unsafe {
                rb_str_locktmp(raw);
            }
        }
        Self { raw, locked }
    }
}

impl Drop for RStringLock {
    fn drop(&mut self) {
        if self.locked {
            unsafe {
                rb_str_unlocktmp(self.raw);
            }
        }
        let _ = rb_sys::rb_gc_guard!(self.raw);
    }
}

fn decompress_error(ruby: &Ruby) -> ExceptionClass {
    ruby.get_inner(
        *DECOMPRESS_ERROR
            .get()
            .expect("DecompressError not initialized"),
    )
}

// ---------- module functions ----------

fn lz4rip_compress_bound(_ruby: &Ruby, size: usize) -> usize {
    block::get_maximum_output_size(size)
}

fn lz4rip_block_stream_size(_ruby: &Ruby) -> usize {
    COMPRESSOR_HEAP_SIZE
}

// ---------- BlockCodec ----------

#[magnus::wrap(class = "Lz4rip::BlockCodec", free_immediately, size)]
struct BlockCodec {
    compressor: Option<RefCell<DictCompressor>>,
    decompressor: Option<Decompressor>,
    dict_len: usize,
}

fn block_codec_new(_ruby: &Ruby, rb_dict: Option<RString>) -> Result<BlockCodec, Error> {
    match rb_dict {
        None => Ok(BlockCodec {
            compressor: None,
            decompressor: None,
            dict_len: 0,
        }),
        Some(rb_dict) => {
            let bytes: Vec<u8> = unsafe { rb_dict.as_slice().to_vec() };
            Ok(BlockCodec {
                compressor: Some(RefCell::new(DictCompressor::new(&bytes))),
                decompressor: Some(Decompressor::with_dict(&bytes)),
                dict_len: bytes.len(),
            })
        }
    }
}

fn block_codec_size(rb_self: &BlockCodec) -> usize {
    if rb_self.compressor.is_some() {
        COMPRESSOR_HEAP_SIZE + rb_self.dict_len
    } else {
        0
    }
}

fn block_codec_has_dict(rb_self: &BlockCodec) -> bool {
    rb_self.compressor.is_some()
}

fn block_codec_compress(
    ruby: &Ruby,
    rb_self: &BlockCodec,
    rb_input: RString,
) -> Result<RString, Error> {
    let release_gvl = should_release_compress_gvl(rb_input.len());
    let _input_lock = release_gvl.then(|| RStringLock::new(rb_input));
    let input: &[u8] = unsafe { rb_input.as_slice() };

    let out = if release_gvl {
        without_gvl(|| match &rb_self.compressor {
            None => block::compress(input),
            Some(comp) => comp.borrow_mut().compress(input),
        })
    } else {
        match &rb_self.compressor {
            None => block::compress(input),
            Some(comp) => comp.borrow_mut().compress(input),
        }
    };

    Ok(ruby.str_from_slice(&out))
}

fn block_codec_decompress(
    ruby: &Ruby,
    rb_self: &BlockCodec,
    rb_input: RString,
    decompressed_size: usize,
) -> Result<RString, Error> {
    let compressed: &[u8] = unsafe { rb_input.as_slice() };

    let result = match &rb_self.decompressor {
        None => block::decompress(compressed, decompressed_size),
        Some(decomp) => decomp.decompress(compressed, decompressed_size),
    };

    match result {
        Ok(data) => Ok(ruby.str_from_slice(&data)),
        Err(e) => Err(Error::new(
            decompress_error(ruby),
            format!("lz4 block decode failed: {e}"),
        )),
    }
}

// ---------- FrameCodec ----------

#[magnus::wrap(class = "Lz4rip::FrameCodec", free_immediately, size)]
struct FrameCodec {
    dict: Option<DictBound>,
}

struct DictBound {
    bytes: Vec<u8>,
    id: u32,
}

fn frame_codec_initialize(
    _ruby: &Ruby,
    rb_dict: Option<RString>,
    id: u32,
) -> Result<FrameCodec, Error> {
    let dict = rb_dict.map(|s| {
        let bytes: Vec<u8> = unsafe { s.as_slice().to_vec() };
        s.freeze();
        DictBound { bytes, id }
    });
    Ok(FrameCodec { dict })
}

fn frame_codec_compress(
    ruby: &Ruby,
    rb_self: &FrameCodec,
    rb_input: RString,
) -> Result<RString, Error> {
    let release_gvl = should_release_compress_gvl(rb_input.len());
    let _input_lock = release_gvl.then(|| RStringLock::new(rb_input));
    let input: &[u8] = unsafe { rb_input.as_slice() };

    let out = if release_gvl {
        without_gvl(|| compress_frame(rb_self, input))
    } else {
        compress_frame(rb_self, input)
    }
    .map_err(|e| Error::new(ruby.exception_runtime_error(), e))?;

    Ok(ruby.str_from_slice(&out))
}

fn compress_frame(rb_self: &FrameCodec, input: &[u8]) -> Result<Vec<u8>, String> {
    let buf = Vec::new();
    let mut enc = match &rb_self.dict {
        None => {
            let info = FrameInfo::new().block_mode(BlockMode::Linked);
            FrameEncoder::with_frame_info(info, buf)
        }
        Some(d) => {
            let info = FrameInfo::new().block_mode(BlockMode::Linked);
            FrameEncoder::with_dictionary(buf, &d.bytes, d.id, Some(info))
                .map_err(|e| format!("lz4 frame compress failed: {e}"))?
        }
    };

    enc.write_all(input)
        .map_err(|e| format!("lz4 frame compress failed: {e}"))?;

    enc.finish()
        .map_err(|e| format!("lz4 frame compress failed: {e}"))
}

fn frame_codec_decompress(
    ruby: &Ruby,
    rb_self: &FrameCodec,
    rb_input: RString,
) -> Result<RString, Error> {
    let release_gvl = should_release_frame_decompress_gvl(rb_input.len());
    let _input_lock = release_gvl.then(|| RStringLock::new(rb_input));
    let input: &[u8] = unsafe { rb_input.as_slice() };

    if input.len() < 4 || input[..4] != LZ4_FRAME_MAGIC {
        return Err(Error::new(
            decompress_error(ruby),
            "lz4 frame decode failed: bad magic (input is not an LZ4 frame)",
        ));
    }

    let out = if release_gvl {
        without_gvl(|| decompress_frame(rb_self, input))
    } else {
        decompress_frame(rb_self, input)
    }
    .map_err(|e| Error::new(decompress_error(ruby), e))?;

    Ok(ruby.str_from_slice(&out))
}

fn decompress_frame(rb_self: &FrameCodec, input: &[u8]) -> Result<Vec<u8>, String> {
    let mut dec = match &rb_self.dict {
        None => FrameDecoder::new(Cursor::new(input)),
        Some(d) => FrameDecoder::with_dictionary(Cursor::new(input), &d.bytes, d.id),
    };

    let mut out = Vec::new();
    dec.read_to_end(&mut out)
        .map_err(|e| format!("lz4 frame decode failed: {e}"))?;
    Ok(out)
}

fn frame_codec_size(rb_self: &FrameCodec) -> usize {
    rb_self.dict.as_ref().map_or(0, |d| d.bytes.len())
}

fn frame_codec_has_dict(rb_self: &FrameCodec) -> bool {
    rb_self.dict.is_some()
}

fn frame_codec_id(rb_self: &FrameCodec) -> Option<u32> {
    rb_self.dict.as_ref().map(|d| d.id)
}

// ---------- DictTrainer ----------

const LZ4_MAX_DISTANCE: usize = 65535;

#[magnus::wrap(class = "Lz4rip::DictTrainer", free_immediately, size)]
struct RbDictTrainer {
    inner: RefCell<Option<DictTrainer>>,
    max_dict_size: usize,
}

fn dict_trainer_new(_ruby: &Ruby, max_dict_size: usize) -> RbDictTrainer {
    let capped = max_dict_size.min(LZ4_MAX_DISTANCE);
    RbDictTrainer {
        max_dict_size: capped,
        inner: RefCell::new(Some(DictTrainer::new(max_dict_size))),
    }
}

fn dict_trainer_add_sample(
    ruby: &Ruby,
    rb_self: &RbDictTrainer,
    rb_data: RString,
) -> Result<(), Error> {
    let mut borrow = rb_self.inner.borrow_mut();
    let trainer = borrow.as_mut().ok_or_else(|| {
        Error::new(
            ruby.exception_runtime_error(),
            "DictTrainer already consumed by #train",
        )
    })?;
    let data: &[u8] = unsafe { rb_data.as_slice() };
    let sample = if data.len() > rb_self.max_dict_size {
        &data[..rb_self.max_dict_size]
    } else {
        data
    };
    trainer.add_sample(sample);
    Ok(())
}

fn dict_trainer_sample_count(ruby: &Ruby, rb_self: &RbDictTrainer) -> Result<usize, Error> {
    let borrow = rb_self.inner.borrow();
    borrow.as_ref().map(|t| t.sample_count()).ok_or_else(|| {
        Error::new(
            ruby.exception_runtime_error(),
            "DictTrainer already consumed by #train",
        )
    })
}

fn dict_trainer_total_bytes(ruby: &Ruby, rb_self: &RbDictTrainer) -> Result<usize, Error> {
    let borrow = rb_self.inner.borrow();
    borrow.as_ref().map(|t| t.total_bytes()).ok_or_else(|| {
        Error::new(
            ruby.exception_runtime_error(),
            "DictTrainer already consumed by #train",
        )
    })
}

fn dict_trainer_train(ruby: &Ruby, rb_self: &RbDictTrainer) -> Result<RString, Error> {
    let trainer = rb_self.inner.borrow_mut().take().ok_or_else(|| {
        Error::new(
            ruby.exception_runtime_error(),
            "DictTrainer already consumed by #train",
        )
    })?;
    let dict = trainer.train();
    Ok(ruby.str_from_slice(&dict))
}

fn dict_trainer_max_dict_size(rb_self: &RbDictTrainer) -> usize {
    rb_self.max_dict_size
}

fn dict_trainer_trained(rb_self: &RbDictTrainer) -> bool {
    rb_self.inner.borrow().is_none()
}

// ---------- module init ----------

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    unsafe { rb_sys::rb_ext_ractor_safe(true) };

    let module = ruby.define_module("Lz4rip")?;

    let decompress_error_class =
        module.define_error("DecompressError", ruby.exception_standard_error())?;
    DECOMPRESS_ERROR
        .set(Opaque::from(decompress_error_class))
        .unwrap_or_else(|_| panic!("init called more than once"));

    module.define_module_function("compress_bound", function!(lz4rip_compress_bound, 1))?;
    module.define_module_function("block_stream_size", function!(lz4rip_block_stream_size, 0))?;

    let codec_class = module.define_class("BlockCodec", ruby.class_object())?;
    codec_class.define_singleton_method("_native_new", function!(block_codec_new, 1))?;
    codec_class.define_method("size", method!(block_codec_size, 0))?;
    codec_class.define_method("has_dict?", method!(block_codec_has_dict, 0))?;
    codec_class.define_method("compress", method!(block_codec_compress, 1))?;
    codec_class.define_method("_decompress", method!(block_codec_decompress, 2))?;

    let trainer_class = module.define_class("DictTrainer", ruby.class_object())?;
    trainer_class.define_singleton_method("_native_new", function!(dict_trainer_new, 1))?;
    trainer_class.define_method("add_sample", method!(dict_trainer_add_sample, 1))?;
    trainer_class.define_method("sample_count", method!(dict_trainer_sample_count, 0))?;
    trainer_class.define_method("total_bytes", method!(dict_trainer_total_bytes, 0))?;
    trainer_class.define_method("train", method!(dict_trainer_train, 0))?;
    trainer_class.define_method("max_dict_size", method!(dict_trainer_max_dict_size, 0))?;
    trainer_class.define_method("trained?", method!(dict_trainer_trained, 0))?;

    let frame_codec_class = module.define_class("FrameCodec", ruby.class_object())?;
    frame_codec_class
        .define_singleton_method("_native_new", function!(frame_codec_initialize, 2))?;
    frame_codec_class.define_method("compress", method!(frame_codec_compress, 1))?;
    frame_codec_class.define_method("decompress", method!(frame_codec_decompress, 1))?;
    frame_codec_class.define_method("size", method!(frame_codec_size, 0))?;
    frame_codec_class.define_method("has_dict?", method!(frame_codec_has_dict, 0))?;
    frame_codec_class.define_method("id", method!(frame_codec_id, 0))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_round_trip() {
        let data = b"hello hello hello hello".to_vec();
        let ct = block::compress(&data);
        let pt = block::decompress(&ct, data.len()).unwrap();
        assert_eq!(pt, data);
    }

    #[test]
    fn block_dict_round_trip() {
        let dict = b"common log prefix: ".to_vec();
        let msg = b"common log prefix: event=login user=alice".to_vec();

        let mut comp = DictCompressor::new(&dict);
        let ct_dict = comp.compress(&msg);
        let decomp = Decompressor::with_dict(&dict);
        let pt = decomp.decompress(&ct_dict, msg.len()).unwrap();
        assert_eq!(pt, msg);

        let ct_plain = block::compress(&msg);
        assert!(
            ct_dict.len() < ct_plain.len(),
            "dict compression should beat no-dict on shared-prefix input"
        );
    }

    #[test]
    fn frame_round_trip() {
        let data = b"the quick brown fox jumps over the lazy dog ".repeat(100);
        let mut enc = FrameEncoder::new(Vec::new());
        enc.write_all(&data).unwrap();
        let ct = enc.finish().unwrap();
        assert!(ct.len() < data.len());
        assert_eq!(&ct[..4], &LZ4_FRAME_MAGIC);

        let mut dec = FrameDecoder::new(Cursor::new(&ct));
        let mut pt = Vec::new();
        dec.read_to_end(&mut pt).unwrap();
        assert_eq!(pt, data);
    }

    #[test]
    fn frame_empty_round_trip() {
        let mut enc = FrameEncoder::new(Vec::new());
        enc.write_all(b"").unwrap();
        let ct = enc.finish().unwrap();

        let mut dec = FrameDecoder::new(Cursor::new(&ct));
        let mut pt = Vec::new();
        dec.read_to_end(&mut pt).unwrap();
        assert!(pt.is_empty());
    }
}
