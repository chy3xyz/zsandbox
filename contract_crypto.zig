//! Guest contract demonstrating cryptographic precompiles.
//! Calls host-provided keccak256 and sha256 hash functions.

extern fn host_log(msg_ptr: i32, msg_len: i32) void;
extern fn keccak256(data_ptr: i32, data_len: i32, out_ptr: i32) void;
extern fn sha256(data_ptr: i32, data_len: i32, out_ptr: i32) void;

/// Hash data at `data_ptr` (len=`data_len`) and write 32-byte results to
/// `keccak_out_ptr` and `sha256_out_ptr`. Returns 0 on success.
export fn hash_both(data_ptr: i32, data_len: i32, keccak_out_ptr: i32, sha256_out_ptr: i32) i32 {
    keccak256(data_ptr, data_len, keccak_out_ptr);
    sha256(data_ptr, data_len, sha256_out_ptr);
    return 0;
}

/// Copy a string to guest memory for hashing demonstration.
/// `dst` = destination pointer, `data_ptr`/`data_len` = input string.
/// Returns `dst`.
export fn copy_string(dst: i32, data_ptr: i32, data_len: i32) i32 {
    const d: [*]u8 = @ptrFromInt(@as(usize, @intCast(dst)));
    const s: [*]const u8 = @ptrFromInt(@as(usize, @intCast(data_ptr)));
    for (0..@intCast(data_len)) |i| {
        d[i] = s[i];
    }
    return dst;
}
