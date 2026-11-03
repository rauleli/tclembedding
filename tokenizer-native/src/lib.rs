use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use tokenizers::{Tokenizer, utils::truncation::TruncationParams};

pub struct HfTokenizer { tokenizer: Tokenizer }

unsafe fn report_error(out: *mut *mut c_char, message: &str) {
    if !out.is_null() {
        let safe = message.replace('\0', "\\0");
        *out = CString::new(safe).expect("NUL removed").into_raw();
    }
}

unsafe fn wrap<F>(error: *mut *mut c_char, f: F) -> i32
where F: FnOnce() -> Result<(), String> {
    if !error.is_null() { *error = ptr::null_mut(); }
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => { report_error(error, &message); 1 },
        Err(_) => { report_error(error, "panic while processing tokenization"); 1 },
    }
}

#[no_mangle]
pub unsafe extern "C" fn hf_load(path: *const c_char, out: *mut *mut HfTokenizer, error: *mut *mut c_char) -> i32 {
    wrap(error, || {
        if !out.is_null() { *out = ptr::null_mut(); }
        if path.is_null() || out.is_null() { return Err("null argument".into()); }
        let path = CStr::from_ptr(path).to_str().map_err(|e| e.to_string())?;
        let mut tokenizer = Tokenizer::from_file(path).map_err(|e| e.to_string())?;
        tokenizer.with_padding(None);
        tokenizer.with_truncation(None).map_err(|e| e.to_string())?;
        *out = Box::into_raw(Box::new(HfTokenizer { tokenizer }));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn hf_encode(handle: *const HfTokenizer, text: *const u8, len: usize, max_length: usize, out: *mut *mut u32, count: *mut usize, error: *mut *mut c_char) -> i32 {
    wrap(error, || {
        if !out.is_null() { *out = ptr::null_mut(); }
        if !count.is_null() { *count = 0; }
        if handle.is_null() || text.is_null() || out.is_null() || count.is_null() { return Err("null argument".into()); }
        if len > isize::MAX as usize { return Err("input too large".into()); }
        let text = std::str::from_utf8(std::slice::from_raw_parts(text, len)).map_err(|e| e.to_string())?;
        let encoding = if max_length == 0 {
            (*handle).tokenizer.encode(text, true).map_err(|e| e.to_string())?
        } else {
            let mut tokenizer = (*handle).tokenizer.clone();
            let params = TruncationParams { max_length, ..Default::default() };
            tokenizer.with_truncation(Some(params)).map_err(|e| e.to_string())?;
            tokenizer.encode(text, true).map_err(|e| e.to_string())?
        };
        if max_length != 0 && encoding.len() > max_length {
            return Err("max_length is smaller than the required special tokens".into());
        }
        let mut ids = encoding.get_ids().to_vec().into_boxed_slice();
        *count = ids.len(); *out = ids.as_mut_ptr();
        std::mem::forget(ids);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn hf_ids_free(ids: *mut u32, count: usize) {
    if !ids.is_null() { drop(Box::from_raw(ptr::slice_from_raw_parts_mut(ids, count))); }
}
#[no_mangle]
pub unsafe extern "C" fn hf_error_free(error: *mut c_char) {
    if !error.is_null() { drop(CString::from_raw(error)); }
}
#[no_mangle]
pub unsafe extern "C" fn hf_tokenizer_free(handle: *mut HfTokenizer) {
    if !handle.is_null() { drop(Box::from_raw(handle)); }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panic_is_reported_as_error() {
        let mut error = ptr::null_mut();
        let status = unsafe {
            wrap(&mut error, || -> Result<(), String> { panic!("synthetic panic") })
        };
        assert_eq!(status, 1);
        assert!(!error.is_null());
        assert_eq!(unsafe { CStr::from_ptr(error) }.to_str().unwrap(),
                   "panic while processing tokenization");
        unsafe { hf_error_free(error); }
    }
}
