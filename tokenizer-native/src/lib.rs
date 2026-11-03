use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::Mutex;
use tokenizers::{Tokenizer, utils::truncation::TruncationParams};

struct TokenizerState { tokenizer: Tokenizer, usable: bool }
pub struct HfTokenizer { state: Mutex<TokenizerState> }

fn encode_locked<F>(handle: &HfTokenizer, max_length: usize, operation: F) -> Result<tokenizers::Encoding, String>
where F: FnOnce(&Tokenizer) -> Result<tokenizers::Encoding, String> {
    let mut state = handle.state.lock().map_err(|_| "tokenizer lock poisoned".to_owned())?;
    if !state.usable { return Err("tokenizer unavailable after panic".into()); }
    let original = state.tokenizer.get_truncation().cloned();
    let result = catch_unwind(AssertUnwindSafe(|| {
        if max_length != 0 {
            state.tokenizer.with_truncation(Some(TruncationParams { max_length, ..Default::default() }))
                .map_err(|e| e.to_string())?;
        }
        operation(&state.tokenizer)
    }));
    if max_length != 0 {
        if let Err(error) = state.tokenizer.with_truncation(original) {
            state.usable = false;
            return Err(format!("tokenizer state restoration failed: {error}"));
        }
    }
    match result {
        Ok(value) => value,
        Err(panic) => {
            state.usable = false;
            drop(state);
            std::panic::resume_unwind(panic)
        }
    }
}

unsafe fn report_error(out: *mut *mut c_char, message: &str) {
    if !out.is_null() {
        let safe = message.replace('\0', "\\0");
        *out = CString::new(safe).expect("NUL removed").into_raw();
    }
}

unsafe fn wrap<F>(error: *mut *mut c_char, f: F) -> i32
where F: FnOnce() -> Result<(), String> {
    match catch_unwind(AssertUnwindSafe(|| {
        if !error.is_null() { *error = ptr::null_mut(); }
        match catch_unwind(AssertUnwindSafe(f)) {
            Ok(Ok(())) => 0,
            Ok(Err(message)) => { report_error(error, &message); 1 },
            Err(_) => { report_error(error, "panic while processing tokenization"); 1 },
        }
    })) {
        Ok(status) => status,
        Err(_) => 1,
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
        *out = Box::into_raw(Box::new(HfTokenizer { state: Mutex::new(TokenizerState { tokenizer, usable: true }) }));
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
        let encoding = encode_locked(&*handle, max_length, |tokenizer| {
            tokenizer.encode(text, true).map_err(|e| e.to_string())
        })?;
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
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !ids.is_null() { drop(Box::from_raw(ptr::slice_from_raw_parts_mut(ids, count))); }
    }));
}
#[no_mangle]
pub unsafe extern "C" fn hf_error_free(error: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !error.is_null() { drop(CString::from_raw(error)); }
    }));
}
#[no_mangle]
pub unsafe extern "C" fn hf_tokenizer_free(handle: *mut HfTokenizer) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !handle.is_null() { drop(Box::from_raw(handle)); }
    }));
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

    fn test_handle() -> HfTokenizer {
        HfTokenizer { state: Mutex::new(TokenizerState {
            tokenizer: Tokenizer::new(tokenizers::models::wordlevel::WordLevel::default()),
            usable: true,
        }) }
    }

    #[test]
    fn error_restores_configuration() {
        let handle = test_handle();
        let err = encode_locked(&handle, 128, |tokenizer| {
            assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
            Err("synthetic failure".into())
        }).unwrap_err();
        assert_eq!(err, "synthetic failure");
        let state = handle.state.lock().unwrap();
        assert!(state.usable && state.tokenizer.get_truncation().is_none());
    }

    #[test]
    fn preexisting_truncation_is_restored() {
        let handle = test_handle();
        handle.state.lock().unwrap().tokenizer.with_truncation(Some(TruncationParams {
            max_length: 64, ..Default::default()
        })).unwrap();
        encode_locked(&handle, 128, |tokenizer| {
            assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
            Ok(tokenizers::Encoding::default())
        }).unwrap();
        assert_eq!(handle.state.lock().unwrap().tokenizer.get_truncation().unwrap().max_length, 64);
    }

    #[test]
    fn panic_restores_then_disables_handle() {
        let handle = test_handle();
        let mut error = ptr::null_mut();
        let status = unsafe { wrap(&mut error, || {
            encode_locked(&handle, 128, |tokenizer| {
                assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
                panic!("synthetic panic after mutation")
            })?;
            Ok(())
        }) };
        assert_eq!(status, 1);
        assert_eq!(unsafe { CStr::from_ptr(error) }.to_str().unwrap(), "panic while processing tokenization");
        unsafe { hf_error_free(error); }
        {
            let state = handle.state.lock().unwrap();
            assert!(!state.usable && state.tokenizer.get_truncation().is_none());
        }
        let err = encode_locked(&handle, 0, |_| Ok(tokenizers::Encoding::default())).unwrap_err();
        assert_eq!(err, "tokenizer unavailable after panic");
        assert_ffi_error(&handle, "tokenizer unavailable after panic");
    }

    fn assert_ffi_error(handle: &HfTokenizer, expected: &str) {
        let mut ids = ptr::null_mut();
        let mut count = 99;
        let mut error = ptr::null_mut();
        let status = unsafe { hf_encode(handle, b"x".as_ptr(), 1, 0, &mut ids, &mut count, &mut error) };
        assert_eq!(status, 1);
        assert!(ids.is_null() && count == 0 && !error.is_null());
        assert_eq!(unsafe { CStr::from_ptr(error) }.to_str().unwrap(), expected);
        unsafe { hf_error_free(error); }
    }

    #[test]
    fn invalidated_loaded_handle_can_be_freed_and_recreated() {
        let path = std::env::var("TOKENIZER_JSON").expect("set TOKENIZER_JSON to the identified test fixture");
        let path = CString::new(path).unwrap();
        let mut handle = ptr::null_mut();
        let mut error = ptr::null_mut();
        assert_eq!(unsafe { hf_load(path.as_ptr(), &mut handle, &mut error) }, 0);
        assert!(!handle.is_null() && error.is_null());
        let status = unsafe { wrap(&mut error, || {
            encode_locked(&*handle, 128, |tokenizer| {
                assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
                panic!("synthetic panic after mutation")
            })?;
            Ok(())
        }) };
        assert_eq!(status, 1);
        assert!(!error.is_null());
        assert_eq!(unsafe { CStr::from_ptr(error) }.to_str().unwrap(), "panic while processing tokenization");
        unsafe { hf_error_free(error); }
        error = ptr::null_mut();
        assert_ffi_error(unsafe { &*handle }, "tokenizer unavailable after panic");
        unsafe { hf_tokenizer_free(handle); }
        handle = ptr::null_mut();
        assert_eq!(unsafe { hf_load(path.as_ptr(), &mut handle, &mut error) }, 0);
        assert!(!handle.is_null() && error.is_null());
        let mut ids = ptr::null_mut();
        let mut count = 0;
        assert_eq!(unsafe { hf_encode(handle, b"hola".as_ptr(), 4, 0, &mut ids, &mut count, &mut error) }, 0);
        assert_eq!(unsafe { std::slice::from_raw_parts(ids, count) }, &[0, 739, 143, 2]);
        unsafe { hf_ids_free(ids, count); hf_tokenizer_free(handle); }
    }

    #[test]
    fn poisoned_mutex_fails_closed() {
        let handle = test_handle();
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let _guard = handle.state.lock().unwrap();
            panic!("synthetic poison");
        }));
        let err = encode_locked(&handle, 0, |_| Ok(tokenizers::Encoding::default())).unwrap_err();
        assert_eq!(err, "tokenizer lock poisoned");
        assert_ffi_error(&handle, "tokenizer lock poisoned");
    }

    #[test]
    fn simultaneous_calls_do_not_share_temporary_configuration() {
        let handle = std::sync::Arc::new(test_handle());
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(4));
        let mut threads = Vec::new();
        for limit in [0, 128, 3, 0] {
            let handle = handle.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                for _ in 0..100 {
                    encode_locked(&handle, limit, |tokenizer| {
                        assert_eq!(tokenizer.get_truncation().map(|p| p.max_length),
                                   if limit == 0 { None } else { Some(limit) });
                        Ok(tokenizers::Encoding::default())
                    }).unwrap();
                }
            }));
        }
        for thread in threads { thread.join().unwrap(); }
        assert!(handle.state.lock().unwrap().tokenizer.get_truncation().is_none());
    }


    #[test]
    fn simultaneous_real_encodes_keep_limits_independent() {
        let path = std::env::var("TOKENIZER_JSON").expect("set TOKENIZER_JSON to the identified test fixture");
        let mut tokenizer = Tokenizer::from_file(path).expect("load tokenizer fixture");
        tokenizer.with_padding(None);
        tokenizer.with_truncation(None).unwrap();
        let handle = std::sync::Arc::new(HfTokenizer { state: Mutex::new(TokenizerState { tokenizer, usable: true }) });
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(4));
        let mut threads = Vec::new();
        for limit in [0, 128, 3, 0] {
            let handle = handle.clone(); let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                for _ in 0..20 {
                    let ids = encode_locked(&handle, limit, |tokenizer| {
                        tokenizer.encode("hola", true).map_err(|e| e.to_string())
                    }).unwrap().get_ids().to_vec();
                    assert_eq!(ids, if limit == 3 { vec![0, 739, 2] } else { vec![0, 739, 143, 2] });
                }
            }));
        }
        for thread in threads { thread.join().unwrap(); }
        assert!(handle.state.lock().unwrap().tokenizer.get_truncation().is_none());
    }

}
