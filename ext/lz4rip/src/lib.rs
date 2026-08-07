mod rb;

use std::ffi::c_void;
use std::io::{Cursor, Read, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, OnceLock, TryLockError};

use lz4::block::{self, Decompressor, DictCompressor, DictTrainer};
use lz4::frame::{BlockMode, FrameDecoder, FrameDecoderOptions, FrameEncoder, FrameInfo};
use rb_sys::{rb_data_type_struct__bindgen_ty_1, rb_data_type_t, size_t, VALUE};

use crate::rb::{RbResult, RubyErr};

const COMPRESSOR_HEAP_SIZE: usize = 8192;

const LZ4_FRAME_MAGIC: [u8; 4] = [0x04, 0x22, 0x4d, 0x18];
const GVL_COMPRESS_THRESHOLD: usize = 256 * 1024;
const GVL_FRAME_DECOMPRESS_THRESHOLD: usize = 256 * 1024;

static DECOMPRESS_ERROR: OnceLock<GlobalValue> = OnceLock::new();

#[derive(Copy, Clone)]
struct GlobalValue(VALUE);

unsafe impl Send for GlobalValue {}
unsafe impl Sync for GlobalValue {}

fn decompress_error() -> VALUE {
    DECOMPRESS_ERROR
        .get()
        .expect("DecompressError not initialized")
        .0
}

fn should_release_compress_gvl(input_len: usize) -> bool {
    input_len >= GVL_COMPRESS_THRESHOLD
}

fn should_release_frame_decompress_gvl(input_len: usize) -> bool {
    input_len >= GVL_FRAME_DECOMPRESS_THRESHOLD
}

fn with_mutex<T, R, F>(mutex: &Mutex<T>, release_gvl: bool, name: &str, func: F) -> RbResult<R>
where
    F: FnOnce(&mut T) -> RbResult<R>,
{
    if release_gvl {
        return rb::maybe_without_gvl(true, || {
            let mut guard = mutex
                .lock()
                .map_err(|_| RubyErr::runtime(format!("{name} mutex poisoned")))?;
            func(&mut guard)
        });
    }

    match mutex.try_lock() {
        Ok(mut guard) => func(&mut guard),
        Err(TryLockError::WouldBlock) => rb::maybe_without_gvl(true, || {
            let mut guard = mutex
                .lock()
                .map_err(|_| RubyErr::runtime(format!("{name} mutex poisoned")))?;
            func(&mut guard)
        }),
        Err(TryLockError::Poisoned(_)) => Err(RubyErr::runtime(format!("{name} mutex poisoned"))),
    }
}

// ---------- typed data ----------

struct NativeDataType(rb_data_type_t);

unsafe impl Send for NativeDataType {}
unsafe impl Sync for NativeDataType {}

static BLOCK_CODEC_DATA_TYPE: OnceLock<NativeDataType> = OnceLock::new();
static FRAME_CODEC_DATA_TYPE: OnceLock<NativeDataType> = OnceLock::new();
static DICT_TRAINER_DATA_TYPE: OnceLock<NativeDataType> = OnceLock::new();

fn block_codec_data_type() -> *const rb_data_type_t {
    &BLOCK_CODEC_DATA_TYPE
        .get_or_init(|| NativeDataType(make_block_codec_data_type()))
        .0
}

fn frame_codec_data_type() -> *const rb_data_type_t {
    &FRAME_CODEC_DATA_TYPE
        .get_or_init(|| NativeDataType(make_frame_codec_data_type()))
        .0
}

fn dict_trainer_data_type() -> *const rb_data_type_t {
    &DICT_TRAINER_DATA_TYPE
        .get_or_init(|| NativeDataType(make_dict_trainer_data_type()))
        .0
}

fn make_block_codec_data_type() -> rb_data_type_t {
    rb_data_type_t {
        wrap_struct_name: c"lz4rip_block_codec".as_ptr(),
        function: rb_data_type_struct__bindgen_ty_1 {
            dmark: None,
            dfree: Some(block_codec_free),
            dsize: Some(block_codec_native_size),
            dcompact: None,
            reserved: [std::ptr::null_mut(); 1],
        },
        parent: std::ptr::null(),
        data: std::ptr::null_mut(),
        flags: 1,
    }
}

fn make_frame_codec_data_type() -> rb_data_type_t {
    rb_data_type_t {
        wrap_struct_name: c"lz4rip_frame_codec".as_ptr(),
        function: rb_data_type_struct__bindgen_ty_1 {
            dmark: None,
            dfree: Some(frame_codec_free),
            dsize: Some(frame_codec_native_size),
            dcompact: None,
            reserved: [std::ptr::null_mut(); 1],
        },
        parent: std::ptr::null(),
        data: std::ptr::null_mut(),
        flags: 1,
    }
}

fn make_dict_trainer_data_type() -> rb_data_type_t {
    rb_data_type_t {
        wrap_struct_name: c"lz4rip_dict_trainer".as_ptr(),
        function: rb_data_type_struct__bindgen_ty_1 {
            dmark: None,
            dfree: Some(dict_trainer_free),
            dsize: Some(dict_trainer_native_size),
            dcompact: None,
            reserved: [std::ptr::null_mut(); 1],
        },
        parent: std::ptr::null(),
        data: std::ptr::null_mut(),
        flags: 1,
    }
}

unsafe extern "C" fn block_codec_free(ptr: *mut c_void) {
    if ptr.is_null() {
        return;
    }

    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(ptr as *mut BlockCodec));
    }));
}

unsafe extern "C" fn frame_codec_free(ptr: *mut c_void) {
    if ptr.is_null() {
        return;
    }

    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(ptr as *mut FrameCodec));
    }));
}

unsafe extern "C" fn dict_trainer_free(ptr: *mut c_void) {
    if ptr.is_null() {
        return;
    }

    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(ptr as *mut RbDictTrainer));
    }));
}

unsafe extern "C" fn block_codec_native_size(_ptr: *const c_void) -> size_t {
    std::mem::size_of::<BlockCodec>() as size_t
}

unsafe extern "C" fn frame_codec_native_size(_ptr: *const c_void) -> size_t {
    std::mem::size_of::<FrameCodec>() as size_t
}

unsafe extern "C" fn dict_trainer_native_size(_ptr: *const c_void) -> size_t {
    std::mem::size_of::<RbDictTrainer>() as size_t
}

unsafe fn block_codec_ref(value: VALUE) -> RbResult<&'static BlockCodec> {
    unsafe { rb::typed_data_ref(value, block_codec_data_type(), "Lz4rip::BlockCodec") }
}

unsafe fn frame_codec_ref(value: VALUE) -> RbResult<&'static FrameCodec> {
    unsafe { rb::typed_data_ref(value, frame_codec_data_type(), "Lz4rip::FrameCodec") }
}

unsafe fn dict_trainer_ref(value: VALUE) -> RbResult<&'static RbDictTrainer> {
    unsafe { rb::typed_data_ref(value, dict_trainer_data_type(), "Lz4rip::DictTrainer") }
}

// ---------- module functions ----------

fn lz4rip_compress_bound_impl(size: VALUE) -> RbResult<VALUE> {
    rb::usize_value(block::get_maximum_output_size(rb::value_to_usize(size)?))
}

fn lz4rip_block_stream_size_impl() -> RbResult<VALUE> {
    rb::usize_value(COMPRESSOR_HEAP_SIZE)
}

unsafe extern "C" fn lz4rip_compress_bound(_module: VALUE, size: VALUE) -> VALUE {
    rb::wrap(|| lz4rip_compress_bound_impl(size))
}

unsafe extern "C" fn lz4rip_block_stream_size(_module: VALUE) -> VALUE {
    rb::wrap(lz4rip_block_stream_size_impl)
}

// ---------- BlockCodec ----------

struct BlockCodec {
    compressor: Option<Mutex<DictCompressor>>,
    decompressor: Option<Mutex<Decompressor>>,
    dict_len: usize,
}

fn block_codec_new_impl(class: VALUE, rb_dict: VALUE) -> RbResult<VALUE> {
    let codec = match rb::value_to_option_bytes(rb_dict)? {
        None => BlockCodec {
            compressor: None,
            decompressor: None,
            dict_len: 0,
        },
        Some(bytes) => BlockCodec {
            compressor: Some(Mutex::new(DictCompressor::new(&bytes))),
            decompressor: Some(Mutex::new(Decompressor::with_dict(&bytes))),
            dict_len: bytes.len(),
        },
    };

    unsafe { rb::wrap_typed_data(class, Box::new(codec), block_codec_data_type()) }
}

fn block_codec_size_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { block_codec_ref(rb_self)? };
    if rb_self.compressor.is_some() {
        rb::usize_value(COMPRESSOR_HEAP_SIZE + rb_self.dict_len)
    } else {
        rb::usize_value(0)
    }
}

fn block_codec_has_dict_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { block_codec_ref(rb_self)? };
    Ok(rb::bool_value(rb_self.compressor.is_some()))
}

fn block_codec_compress_impl(rb_self: VALUE, rb_input: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { block_codec_ref(rb_self)? };
    let mut input = rb::input_bytes(rb_input)?;
    let release_gvl = should_release_compress_gvl(input.len());
    input.lock_for_without_gvl(release_gvl)?;

    let out = match &rb_self.compressor {
        None => rb::maybe_without_gvl(release_gvl, || Ok(block::compress(input.as_slice())))?,
        Some(comp) => with_mutex(comp, release_gvl, "BlockCodec compressor", |comp| {
            Ok(comp.compress(input.as_slice()))
        })?,
    };

    rb::new_binary_string(&out)
}

fn block_codec_decompress_impl(
    rb_self: VALUE,
    rb_input: VALUE,
    decompressed_size: VALUE,
) -> RbResult<VALUE> {
    let rb_self = unsafe { block_codec_ref(rb_self)? };
    let compressed = rb::input_bytes(rb_input)?;
    let decompressed_size = rb::value_to_usize(decompressed_size)?;

    let result = match &rb_self.decompressor {
        None => block::decompress(compressed.as_slice(), decompressed_size),
        Some(decomp) => with_mutex(decomp, false, "BlockCodec decompressor", |decomp| {
            Ok(decomp.decompress(compressed.as_slice(), decompressed_size))
        })?,
    };

    match result {
        Ok(data) => rb::new_binary_string(&data),
        Err(e) => Err(RubyErr::new(
            decompress_error(),
            format!("lz4 block decode failed: {e}"),
        )),
    }
}

unsafe extern "C" fn block_codec_new(class: VALUE, rb_dict: VALUE) -> VALUE {
    rb::wrap(|| block_codec_new_impl(class, rb_dict))
}

unsafe extern "C" fn block_codec_size(rb_self: VALUE) -> VALUE {
    rb::wrap(|| block_codec_size_impl(rb_self))
}

unsafe extern "C" fn block_codec_has_dict(rb_self: VALUE) -> VALUE {
    rb::wrap(|| block_codec_has_dict_impl(rb_self))
}

unsafe extern "C" fn block_codec_compress(rb_self: VALUE, rb_input: VALUE) -> VALUE {
    rb::wrap(|| block_codec_compress_impl(rb_self, rb_input))
}

unsafe extern "C" fn block_codec_decompress(
    rb_self: VALUE,
    rb_input: VALUE,
    decompressed_size: VALUE,
) -> VALUE {
    rb::wrap(|| block_codec_decompress_impl(rb_self, rb_input, decompressed_size))
}

// ---------- FrameCodec ----------

struct FrameCodec {
    dict: Option<DictBound>,
}

struct DictBound {
    bytes: Vec<u8>,
    id: u32,
}

fn frame_codec_new_impl(class: VALUE, rb_dict: VALUE, id: VALUE) -> RbResult<VALUE> {
    let id = rb::value_to_u32(id)?;
    let dict = if rb_dict == rb::qnil() {
        None
    } else {
        let rb_dict = rb::string_value(rb_dict)?;
        rb::freeze_value(rb_dict)?;
        Some(DictBound {
            bytes: rb::value_to_bytes(rb_dict)?,
            id,
        })
    };
    unsafe {
        rb::wrap_typed_data(
            class,
            Box::new(FrameCodec { dict }),
            frame_codec_data_type(),
        )
    }
}

fn frame_codec_compress_impl(rb_self: VALUE, rb_input: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { frame_codec_ref(rb_self)? };
    let mut input = rb::input_bytes(rb_input)?;
    let release_gvl = should_release_compress_gvl(input.len());
    input.lock_for_without_gvl(release_gvl)?;

    let out = rb::maybe_without_gvl(release_gvl, || compress_frame(rb_self, input.as_slice()))
        .map_err(RubyErr::runtime)?;

    rb::new_binary_string(&out)
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

fn frame_codec_decompress_impl(
    rb_self: VALUE,
    rb_input: VALUE,
    max_decompressed_size: VALUE,
) -> RbResult<VALUE> {
    let rb_self = unsafe { frame_codec_ref(rb_self)? };
    let mut input = rb::input_bytes(rb_input)?;
    let max_decompressed_size = rb::value_to_option_usize(max_decompressed_size)?;
    let release_gvl = should_release_frame_decompress_gvl(input.len());
    input.lock_for_without_gvl(release_gvl)?;

    if input.len() < 4 || input.as_slice()[..4] != LZ4_FRAME_MAGIC {
        return Err(RubyErr::new(
            decompress_error(),
            "lz4 frame decode failed: bad magic (input is not an LZ4 frame)",
        ));
    }

    let out = rb::maybe_without_gvl(release_gvl, || {
        decompress_frame(rb_self, input.as_slice(), max_decompressed_size)
    })
    .map_err(|e| RubyErr::new(decompress_error(), e))?;

    rb::new_binary_string(&out)
}

fn decompress_frame(
    rb_self: &FrameCodec,
    input: &[u8],
    max_decompressed_size: Option<usize>,
) -> Result<Vec<u8>, String> {
    let mut dec = FrameDecoder::with_options(
        Cursor::new(input),
        FrameDecoderOptions {
            dictionary: rb_self.dict.as_ref().map(|d| (d.bytes.as_slice(), d.id)),
            max_output: max_decompressed_size,
        },
    );

    let mut out = Vec::new();
    dec.read_to_end(&mut out)
        .map_err(|e| format!("lz4 frame decode failed: {e}"))?;
    Ok(out)
}

fn frame_codec_size_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { frame_codec_ref(rb_self)? };
    rb::usize_value(rb_self.dict.as_ref().map_or(0, |d| d.bytes.len()))
}

fn frame_codec_has_dict_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { frame_codec_ref(rb_self)? };
    Ok(rb::bool_value(rb_self.dict.is_some()))
}

fn frame_codec_id_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { frame_codec_ref(rb_self)? };
    rb::u32_option_value(rb_self.dict.as_ref().map(|d| d.id))
}

unsafe extern "C" fn frame_codec_new(class: VALUE, rb_dict: VALUE, id: VALUE) -> VALUE {
    rb::wrap(|| frame_codec_new_impl(class, rb_dict, id))
}

unsafe extern "C" fn frame_codec_compress(rb_self: VALUE, rb_input: VALUE) -> VALUE {
    rb::wrap(|| frame_codec_compress_impl(rb_self, rb_input))
}

unsafe extern "C" fn frame_codec_decompress(
    rb_self: VALUE,
    rb_input: VALUE,
    max_decompressed_size: VALUE,
) -> VALUE {
    rb::wrap(|| frame_codec_decompress_impl(rb_self, rb_input, max_decompressed_size))
}

unsafe extern "C" fn frame_codec_size(rb_self: VALUE) -> VALUE {
    rb::wrap(|| frame_codec_size_impl(rb_self))
}

unsafe extern "C" fn frame_codec_has_dict(rb_self: VALUE) -> VALUE {
    rb::wrap(|| frame_codec_has_dict_impl(rb_self))
}

unsafe extern "C" fn frame_codec_id(rb_self: VALUE) -> VALUE {
    rb::wrap(|| frame_codec_id_impl(rb_self))
}

// ---------- DictTrainer ----------

const LZ4_MAX_DISTANCE: usize = 65535;

struct RbDictTrainer {
    inner: Mutex<Option<DictTrainer>>,
    max_dict_size: usize,
}

fn dict_trainer_new_impl(class: VALUE, max_dict_size: VALUE) -> RbResult<VALUE> {
    let max_dict_size = rb::value_to_usize(max_dict_size)?;
    let capped = max_dict_size.min(LZ4_MAX_DISTANCE);
    unsafe {
        rb::wrap_typed_data(
            class,
            Box::new(RbDictTrainer {
                max_dict_size: capped,
                inner: Mutex::new(Some(DictTrainer::new(max_dict_size))),
            }),
            dict_trainer_data_type(),
        )
    }
}

fn dict_trainer_add_sample_impl(rb_self: VALUE, rb_data: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { dict_trainer_ref(rb_self)? };
    let mut borrow = rb_self
        .inner
        .lock()
        .map_err(|_| RubyErr::runtime("DictTrainer mutex poisoned"))?;
    let trainer = borrow
        .as_mut()
        .ok_or_else(|| RubyErr::runtime("DictTrainer already consumed by #train"))?;
    let data = rb::input_bytes(rb_data)?;
    let sample = if data.len() > rb_self.max_dict_size {
        &data.as_slice()[..rb_self.max_dict_size]
    } else {
        data.as_slice()
    };
    trainer.add_sample(sample);
    Ok(rb::qnil())
}

fn dict_trainer_sample_count_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { dict_trainer_ref(rb_self)? };
    let borrow = rb_self
        .inner
        .lock()
        .map_err(|_| RubyErr::runtime("DictTrainer mutex poisoned"))?;
    let value = borrow
        .as_ref()
        .map(|t| t.sample_count())
        .ok_or_else(|| RubyErr::runtime("DictTrainer already consumed by #train"))?;
    rb::usize_value(value)
}

fn dict_trainer_total_bytes_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { dict_trainer_ref(rb_self)? };
    let borrow = rb_self
        .inner
        .lock()
        .map_err(|_| RubyErr::runtime("DictTrainer mutex poisoned"))?;
    let value = borrow
        .as_ref()
        .map(|t| t.total_bytes())
        .ok_or_else(|| RubyErr::runtime("DictTrainer already consumed by #train"))?;
    rb::usize_value(value)
}

fn dict_trainer_train_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { dict_trainer_ref(rb_self)? };
    let trainer = rb_self
        .inner
        .lock()
        .map_err(|_| RubyErr::runtime("DictTrainer mutex poisoned"))?
        .take()
        .ok_or_else(|| RubyErr::runtime("DictTrainer already consumed by #train"))?;
    let dict = trainer.train();
    rb::new_binary_string(&dict)
}

fn dict_trainer_max_dict_size_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { dict_trainer_ref(rb_self)? };
    rb::usize_value(rb_self.max_dict_size)
}

fn dict_trainer_trained_impl(rb_self: VALUE) -> RbResult<VALUE> {
    let rb_self = unsafe { dict_trainer_ref(rb_self)? };
    let borrow = rb_self
        .inner
        .lock()
        .map_err(|_| RubyErr::runtime("DictTrainer mutex poisoned"))?;
    Ok(rb::bool_value(borrow.is_none()))
}

unsafe extern "C" fn dict_trainer_new(class: VALUE, max_dict_size: VALUE) -> VALUE {
    rb::wrap(|| dict_trainer_new_impl(class, max_dict_size))
}

unsafe extern "C" fn dict_trainer_add_sample(rb_self: VALUE, rb_data: VALUE) -> VALUE {
    rb::wrap(|| dict_trainer_add_sample_impl(rb_self, rb_data))
}

unsafe extern "C" fn dict_trainer_sample_count(rb_self: VALUE) -> VALUE {
    rb::wrap(|| dict_trainer_sample_count_impl(rb_self))
}

unsafe extern "C" fn dict_trainer_total_bytes(rb_self: VALUE) -> VALUE {
    rb::wrap(|| dict_trainer_total_bytes_impl(rb_self))
}

unsafe extern "C" fn dict_trainer_train(rb_self: VALUE) -> VALUE {
    rb::wrap(|| dict_trainer_train_impl(rb_self))
}

unsafe extern "C" fn dict_trainer_max_dict_size(rb_self: VALUE) -> VALUE {
    rb::wrap(|| dict_trainer_max_dict_size_impl(rb_self))
}

unsafe extern "C" fn dict_trainer_trained(rb_self: VALUE) -> VALUE {
    rb::wrap(|| dict_trainer_trained_impl(rb_self))
}

// ---------- module init ----------

/// # Safety
///
/// Ruby calls this function while loading the native extension. The Ruby VM
/// must be initialized, and the symbol must only be entered by Ruby's extension
/// loader.
#[no_mangle]
pub unsafe extern "C" fn Init_lz4rip() {
    rb::wrap_init(init);
}

fn init() -> RbResult<()> {
    #[cfg(ruby_engine = "mri")]
    unsafe {
        rb_sys::rb_ext_ractor_safe(true);
    }

    let module = unsafe { rb::define_module(c"Lz4rip")? };

    let decompress_error_class =
        unsafe { rb::define_error_under(module, c"DecompressError", rb_sys::rb_eStandardError)? };
    DECOMPRESS_ERROR
        .set(GlobalValue(decompress_error_class))
        .unwrap_or_else(|_| panic!("init called more than once"));

    unsafe {
        rb::define_module_function_1(module, c"compress_bound", lz4rip_compress_bound)?;
        rb::define_module_function_0(module, c"block_stream_size", lz4rip_block_stream_size)?;
    }

    let codec_class = unsafe { rb::define_class_under(module, c"BlockCodec", rb_sys::rb_cObject)? };
    unsafe {
        rb::undef_alloc_func(codec_class)?;
        rb::define_singleton_method_1(codec_class, c"_native_new", block_codec_new)?;
        rb::define_method_0(codec_class, c"size", block_codec_size)?;
        rb::define_method_0(codec_class, c"has_dict?", block_codec_has_dict)?;
        rb::define_method_1(codec_class, c"compress", block_codec_compress)?;
        rb::define_method_2(codec_class, c"_decompress", block_codec_decompress)?;
    }

    let trainer_class =
        unsafe { rb::define_class_under(module, c"DictTrainer", rb_sys::rb_cObject)? };
    unsafe {
        rb::undef_alloc_func(trainer_class)?;
        rb::define_singleton_method_1(trainer_class, c"_native_new", dict_trainer_new)?;
        rb::define_method_1(trainer_class, c"add_sample", dict_trainer_add_sample)?;
        rb::define_method_0(trainer_class, c"sample_count", dict_trainer_sample_count)?;
        rb::define_method_0(trainer_class, c"total_bytes", dict_trainer_total_bytes)?;
        rb::define_method_0(trainer_class, c"train", dict_trainer_train)?;
        rb::define_method_0(trainer_class, c"max_dict_size", dict_trainer_max_dict_size)?;
        rb::define_method_0(trainer_class, c"trained?", dict_trainer_trained)?;
    }

    let frame_codec_class =
        unsafe { rb::define_class_under(module, c"FrameCodec", rb_sys::rb_cObject)? };
    unsafe {
        rb::undef_alloc_func(frame_codec_class)?;
        rb::define_singleton_method_2(frame_codec_class, c"_native_new", frame_codec_new)?;
        rb::define_method_1(frame_codec_class, c"compress", frame_codec_compress)?;
        rb::define_method_2(frame_codec_class, c"_decompress", frame_codec_decompress)?;
        rb::define_method_0(frame_codec_class, c"size", frame_codec_size)?;
        rb::define_method_0(frame_codec_class, c"has_dict?", frame_codec_has_dict)?;
        rb::define_method_0(frame_codec_class, c"id", frame_codec_id)?;
    }

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
