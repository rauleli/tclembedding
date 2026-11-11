use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::Mutex;
use tokenizers::{utils::truncation::TruncationParams, Tokenizer};

struct TokenizerState {
    tokenizer: Tokenizer,
    usable: bool,
}
pub struct HfTokenizer {
    state: Mutex<TokenizerState>,
}

#[repr(C)]
pub struct HfTokenDetail {
    byte_start: u64,
    byte_end: u64,
    id: u32,
    special_mask: u32,
    attention_mask: u32,
    type_id: u32,
}

fn encode_locked<F>(
    handle: &HfTokenizer,
    max_length: usize,
    operation: F,
) -> Result<tokenizers::Encoding, String>
where
    F: FnOnce(&Tokenizer) -> Result<tokenizers::Encoding, String>,
{
    let mut state = handle
        .state
        .lock()
        .map_err(|_| "tokenizer lock poisoned".to_owned())?;
    if !state.usable {
        return Err("tokenizer unavailable after panic".into());
    }
    let original = state.tokenizer.get_truncation().cloned();
    let result = catch_unwind(AssertUnwindSafe(|| {
        if max_length != 0 {
            state
                .tokenizer
                .with_truncation(Some(TruncationParams {
                    max_length,
                    ..Default::default()
                }))
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
where
    F: FnOnce() -> Result<(), String>,
{
    match catch_unwind(AssertUnwindSafe(|| {
        if !error.is_null() {
            *error = ptr::null_mut();
        }
        match catch_unwind(AssertUnwindSafe(f)) {
            Ok(Ok(())) => 0,
            Ok(Err(message)) => {
                report_error(error, &message);
                1
            }
            Err(_) => {
                report_error(error, "panic while processing tokenization");
                1
            }
        }
    })) {
        Ok(status) => status,
        Err(_) => 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn hf_load(
    path: *const c_char,
    out: *mut *mut HfTokenizer,
    error: *mut *mut c_char,
) -> i32 {
    wrap(error, || {
        if !out.is_null() {
            *out = ptr::null_mut();
        }
        if path.is_null() || out.is_null() {
            return Err("null argument".into());
        }
        let path = CStr::from_ptr(path).to_str().map_err(|e| e.to_string())?;
        let mut tokenizer = Tokenizer::from_file(path).map_err(|e| e.to_string())?;
        tokenizer.with_padding(None);
        tokenizer.with_truncation(None).map_err(|e| e.to_string())?;
        *out = Box::into_raw(Box::new(HfTokenizer {
            state: Mutex::new(TokenizerState {
                tokenizer,
                usable: true,
            }),
        }));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn hf_encode(
    handle: *const HfTokenizer,
    text: *const u8,
    len: usize,
    max_length: usize,
    out: *mut *mut u32,
    count: *mut usize,
    error: *mut *mut c_char,
) -> i32 {
    wrap(error, || {
        if !out.is_null() {
            *out = ptr::null_mut();
        }
        if !count.is_null() {
            *count = 0;
        }
        if handle.is_null() || text.is_null() || out.is_null() || count.is_null() {
            return Err("null argument".into());
        }
        if len > isize::MAX as usize {
            return Err("input too large".into());
        }
        let text = std::str::from_utf8(std::slice::from_raw_parts(text, len))
            .map_err(|e| e.to_string())?;
        let encoding = encode_locked(&*handle, max_length, |tokenizer| {
            tokenizer.encode(text, true).map_err(|e| e.to_string())
        })?;
        if max_length != 0 && encoding.len() > max_length {
            return Err("max_length is smaller than the required special tokens".into());
        }
        let mut ids = encoding.get_ids().to_vec().into_boxed_slice();
        *count = ids.len();
        *out = ids.as_mut_ptr();
        std::mem::forget(ids);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn hf_encode_details(
    handle: *const HfTokenizer,
    text: *const u8,
    len: usize,
    max_length: usize,
    out: *mut *mut HfTokenDetail,
    count: *mut usize,
    error: *mut *mut c_char,
) -> i32 {
    wrap(error, || {
        if !out.is_null() {
            *out = ptr::null_mut();
        }
        if !count.is_null() {
            *count = 0;
        }
        if handle.is_null() || text.is_null() || out.is_null() || count.is_null() {
            return Err("null argument".into());
        }
        if len > isize::MAX as usize {
            return Err("input too large".into());
        }
        let text = std::str::from_utf8(std::slice::from_raw_parts(text, len))
            .map_err(|e| e.to_string())?;
        let enc = encode_locked(&*handle, max_length, |tokenizer| {
            tokenizer.encode(text, true).map_err(|e| e.to_string())
        })?;
        if max_length != 0 && enc.len() > max_length {
            return Err("max_length is smaller than the required special tokens".into());
        }
        let n = enc.len();
        let ids = enc.get_ids();
        let offsets = enc.get_offsets();
        let special = enc.get_special_tokens_mask();
        let attention = enc.get_attention_mask();
        let types = enc.get_type_ids();
        if [
            ids.len(),
            offsets.len(),
            special.len(),
            attention.len(),
            types.len(),
        ]
        .iter()
        .any(|&v| v != n)
        {
            return Err("inconsistent encoding lengths".into());
        }
        let mut result = Vec::with_capacity(n);
        for i in 0..n {
            let (start, end) = offsets[i];
            if start > end || end > text.len() {
                return Err("invalid byte offsets in encoding".into());
            }
            result.push(HfTokenDetail {
                byte_start: u64::try_from(start).map_err(|_| "offset overflow")?,
                byte_end: u64::try_from(end).map_err(|_| "offset overflow")?,
                id: ids[i],
                special_mask: special[i],
                attention_mask: attention[i],
                type_id: types[i],
            });
        }
        if n != 0 {
            let mut boxed = result.into_boxed_slice();
            *out = boxed.as_mut_ptr();
            *count = n;
            std::mem::forget(boxed);
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn hf_details_free(out: *mut *mut HfTokenDetail, count: *mut usize) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !out.is_null() && !count.is_null() {
            let data = *out;
            let len = *count;
            *out = ptr::null_mut();
            *count = 0;
            if !data.is_null() {
                drop(Box::from_raw(ptr::slice_from_raw_parts_mut(data, len)));
            }
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn hf_ids_free(ids: *mut u32, count: usize) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !ids.is_null() {
            drop(Box::from_raw(ptr::slice_from_raw_parts_mut(ids, count)));
        }
    }));
}
#[no_mangle]
pub unsafe extern "C" fn hf_error_free(error: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !error.is_null() {
            drop(CString::from_raw(error));
        }
    }));
}
#[no_mangle]
pub unsafe extern "C" fn hf_tokenizer_free(handle: *mut HfTokenizer) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle));
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_and_character_offsets_for_identified_model() {
        let path = std::env::var("TOKENIZER_JSON").expect("set TOKENIZER_JSON");
        let mut tokenizer = Tokenizer::from_file(path).unwrap();
        tokenizer.with_padding(None);
        tokenizer.with_truncation(None).unwrap();
        let bytes = tokenizer.encode("café 😀", true).unwrap();
        let chars = tokenizer.encode_char_offsets("café 😀", true).unwrap();
        assert_eq!(bytes.get_ids(), chars.get_ids());
        assert_eq!(bytes.get_offsets(), &[(0, 0), (0, 5), (6, 10), (0, 0)]);
        assert_eq!(chars.get_offsets(), &[(0, 0), (0, 4), (5, 6), (0, 0)]);
        assert_eq!(bytes.get_special_tokens_mask(), &[1, 0, 0, 1]);
        assert_eq!(bytes.get_attention_mask(), &[1, 1, 1, 1]);
        assert_eq!(bytes.get_type_ids(), &[0, 0, 0, 0]);
        assert_eq!(std::mem::size_of::<HfTokenDetail>(), 32);
    }

    #[test]
    fn byte_and_character_offsets_for_additional_fixtures() {
        let Some(paths) = std::env::var_os("TOKENIZER_EXTRA_JSONS") else {
            return;
        };
        for path in std::env::split_paths(&paths) {
            let mut tokenizer = Tokenizer::from_file(path).unwrap();
            tokenizer.with_padding(None);
            tokenizer.with_truncation(None).unwrap();
            let input = "café 😀";
            let b = tokenizer.encode(input, true).unwrap();
            let c = tokenizer.encode_char_offsets(input, true).unwrap();
            assert_eq!(b.get_ids(), c.get_ids());
            for (&(start, end), &(cs, ce)) in b.get_offsets().iter().zip(c.get_offsets()) {
                assert!(input.is_char_boundary(start) && input.is_char_boundary(end));
                assert_eq!(
                    (input[..start].chars().count(), input[..end].chars().count()),
                    (cs, ce)
                );
            }
        }
    }

    #[test]
    fn concurrent_detail_calls_preserve_truncation() {
        let path = std::env::var("TOKENIZER_JSON").expect("set TOKENIZER_JSON");
        let mut tokenizer = Tokenizer::from_file(path).unwrap();
        tokenizer.with_padding(None);
        tokenizer.with_truncation(None).unwrap();
        let h = std::sync::Arc::new(HfTokenizer {
            state: Mutex::new(TokenizerState {
                tokenizer,
                usable: true,
            }),
        });
        let mut threads = Vec::new();
        for limit in [0, 3, 0, 3] {
            let h = h.clone();
            threads.push(std::thread::spawn(move || {
                for _ in 0..10 {
                    let mut data = ptr::null_mut();
                    let mut n = 0;
                    let mut error = ptr::null_mut();
                    let status = unsafe {
                        hf_encode_details(
                            &*h,
                            b"hola".as_ptr(),
                            4,
                            limit,
                            &mut data,
                            &mut n,
                            &mut error,
                        )
                    };
                    assert_eq!(status, 0);
                    assert!(error.is_null());
                    let values: Vec<u32> = unsafe { std::slice::from_raw_parts(data, n) }
                        .iter()
                        .map(|v| v.id)
                        .collect();
                    assert_eq!(
                        values,
                        if limit == 3 {
                            vec![0, 739, 2]
                        } else {
                            vec![0, 739, 143, 2]
                        }
                    );
                    unsafe {
                        hf_details_free(&mut data, &mut n);
                        hf_details_free(&mut data, &mut n);
                    }
                    assert!(data.is_null() && n == 0);
                }
            }));
        }
        for t in threads {
            t.join().unwrap();
        }
    }

    #[test]
    fn panic_is_reported_as_error() {
        let mut error = ptr::null_mut();
        let status = unsafe {
            wrap(&mut error, || -> Result<(), String> {
                panic!("synthetic panic")
            })
        };
        assert_eq!(status, 1);
        assert!(!error.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(error) }.to_str().unwrap(),
            "panic while processing tokenization"
        );
        unsafe {
            hf_error_free(error);
        }
    }

    fn test_handle() -> HfTokenizer {
        HfTokenizer {
            state: Mutex::new(TokenizerState {
                tokenizer: Tokenizer::new(tokenizers::models::wordlevel::WordLevel::default()),
                usable: true,
            }),
        }
    }

    #[test]
    fn error_restores_configuration() {
        let handle = test_handle();
        let err = encode_locked(&handle, 128, |tokenizer| {
            assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
            Err("synthetic failure".into())
        })
        .unwrap_err();
        assert_eq!(err, "synthetic failure");
        let state = handle.state.lock().unwrap();
        assert!(state.usable && state.tokenizer.get_truncation().is_none());
    }

    #[test]
    fn preexisting_truncation_is_restored() {
        let handle = test_handle();
        handle
            .state
            .lock()
            .unwrap()
            .tokenizer
            .with_truncation(Some(TruncationParams {
                max_length: 64,
                ..Default::default()
            }))
            .unwrap();
        encode_locked(&handle, 128, |tokenizer| {
            assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
            Ok(tokenizers::Encoding::default())
        })
        .unwrap();
        assert_eq!(
            handle
                .state
                .lock()
                .unwrap()
                .tokenizer
                .get_truncation()
                .unwrap()
                .max_length,
            64
        );
    }

    #[test]
    fn panic_restores_then_disables_handle() {
        let handle = test_handle();
        let mut error = ptr::null_mut();
        let status = unsafe {
            wrap(&mut error, || {
                encode_locked(&handle, 128, |tokenizer| {
                    assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
                    panic!("synthetic panic after mutation")
                })?;
                Ok(())
            })
        };
        assert_eq!(status, 1);
        assert_eq!(
            unsafe { CStr::from_ptr(error) }.to_str().unwrap(),
            "panic while processing tokenization"
        );
        unsafe {
            hf_error_free(error);
        }
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
        let status = unsafe {
            hf_encode(
                handle,
                b"x".as_ptr(),
                1,
                0,
                &mut ids,
                &mut count,
                &mut error,
            )
        };
        assert_eq!(status, 1);
        assert!(ids.is_null() && count == 0 && !error.is_null());
        assert_eq!(unsafe { CStr::from_ptr(error) }.to_str().unwrap(), expected);
        unsafe {
            hf_error_free(error);
        }
    }

    #[test]
    fn invalidated_loaded_handle_can_be_freed_and_recreated() {
        let path = std::env::var("TOKENIZER_JSON")
            .expect("set TOKENIZER_JSON to the identified test fixture");
        let path = CString::new(path).unwrap();
        let mut handle = ptr::null_mut();
        let mut error = ptr::null_mut();
        assert_eq!(
            unsafe { hf_load(path.as_ptr(), &mut handle, &mut error) },
            0
        );
        assert!(!handle.is_null() && error.is_null());
        let status = unsafe {
            wrap(&mut error, || {
                encode_locked(&*handle, 128, |tokenizer| {
                    assert_eq!(tokenizer.get_truncation().unwrap().max_length, 128);
                    panic!("synthetic panic after mutation")
                })?;
                Ok(())
            })
        };
        assert_eq!(status, 1);
        assert!(!error.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(error) }.to_str().unwrap(),
            "panic while processing tokenization"
        );
        unsafe {
            hf_error_free(error);
        }
        error = ptr::null_mut();
        assert_ffi_error(unsafe { &*handle }, "tokenizer unavailable after panic");
        unsafe {
            hf_tokenizer_free(handle);
        }
        handle = ptr::null_mut();
        assert_eq!(
            unsafe { hf_load(path.as_ptr(), &mut handle, &mut error) },
            0
        );
        assert!(!handle.is_null() && error.is_null());
        let mut ids = ptr::null_mut();
        let mut count = 0;
        assert_eq!(
            unsafe {
                hf_encode(
                    handle,
                    b"hola".as_ptr(),
                    4,
                    0,
                    &mut ids,
                    &mut count,
                    &mut error,
                )
            },
            0
        );
        assert_eq!(
            unsafe { std::slice::from_raw_parts(ids, count) },
            &[0, 739, 143, 2]
        );
        unsafe {
            hf_ids_free(ids, count);
            hf_tokenizer_free(handle);
        }
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
                        assert_eq!(
                            tokenizer.get_truncation().map(|p| p.max_length),
                            if limit == 0 { None } else { Some(limit) }
                        );
                        Ok(tokenizers::Encoding::default())
                    })
                    .unwrap();
                }
            }));
        }
        for thread in threads {
            thread.join().unwrap();
        }
        assert!(handle
            .state
            .lock()
            .unwrap()
            .tokenizer
            .get_truncation()
            .is_none());
    }

    #[test]
    fn simultaneous_real_encodes_keep_limits_independent() {
        let path = std::env::var("TOKENIZER_JSON")
            .expect("set TOKENIZER_JSON to the identified test fixture");
        let mut tokenizer = Tokenizer::from_file(path).expect("load tokenizer fixture");
        tokenizer.with_padding(None);
        tokenizer.with_truncation(None).unwrap();
        let handle = std::sync::Arc::new(HfTokenizer {
            state: Mutex::new(TokenizerState {
                tokenizer,
                usable: true,
            }),
        });
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(4));
        let mut threads = Vec::new();
        for limit in [0, 128, 3, 0] {
            let handle = handle.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                for _ in 0..20 {
                    let ids = encode_locked(&handle, limit, |tokenizer| {
                        tokenizer.encode("hola", true).map_err(|e| e.to_string())
                    })
                    .unwrap()
                    .get_ids()
                    .to_vec();
                    assert_eq!(
                        ids,
                        if limit == 3 {
                            vec![0, 739, 2]
                        } else {
                            vec![0, 739, 143, 2]
                        }
                    );
                }
            }));
        }
        for thread in threads {
            thread.join().unwrap();
        }
        assert!(handle
            .state
            .lock()
            .unwrap()
            .tokenizer
            .get_truncation()
            .is_none());
    }
}
