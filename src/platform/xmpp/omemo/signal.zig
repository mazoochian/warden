//! Hand-written bindings for libomemo-c (the maintained libsignal-protocol-c
//! fork with OMEMO support). Only what the legacy OMEMO (0.3,
//! `eu.siacs.conversations.axolotl`) flow needs.

pub const SG_SUCCESS: c_int = 0;
pub const SG_ERR_NOMEM: c_int = -12;
pub const SG_ERR_INVAL: c_int = -22;
pub const SG_ERR_UNKNOWN: c_int = -1000;
pub const SG_ERR_DUPLICATE_MESSAGE: c_int = -1001;
pub const SG_ERR_INVALID_KEY: c_int = -1002;
pub const SG_ERR_INVALID_KEY_ID: c_int = -1003;
pub const SG_ERR_INVALID_MAC: c_int = -1004;
pub const SG_ERR_INVALID_MESSAGE: c_int = -1005;
pub const SG_ERR_NO_SESSION: c_int = -1008;
pub const SG_ERR_UNTRUSTED_IDENTITY: c_int = -1010;

pub const SG_CIPHER_AES_CTR_NOPADDING: c_int = 1;
pub const SG_CIPHER_AES_CBC_PKCS5: c_int = 2;

pub const CIPHERTEXT_SIGNAL_TYPE: c_int = 2;
pub const CIPHERTEXT_PREKEY_TYPE: c_int = 3;

pub const signal_type_base = opaque {};
pub const signal_buffer = opaque {};
pub const signal_int_list = opaque {};
pub const signal_context = opaque {};
pub const signal_protocol_store_context = opaque {};
pub const ec_public_key = opaque {};
pub const ec_private_key = opaque {};
pub const ec_key_pair = opaque {};
pub const ratchet_identity_key_pair = opaque {};
pub const session_pre_key = opaque {};
pub const session_signed_pre_key = opaque {};
pub const session_pre_key_bundle = opaque {};
pub const session_builder = opaque {};
pub const session_cipher = opaque {};
pub const ciphertext_message = opaque {};
pub const signal_message = opaque {};
pub const pre_key_signal_message = opaque {};
pub const pre_key_list_node = opaque {};
pub const sender_key_name = opaque {};

pub const signal_protocol_address = extern struct {
    name: [*]const u8,
    name_len: usize,
    device_id: i32,
};

pub const signal_crypto_provider = extern struct {
    random_func: *const fn (data: [*]u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    hmac_sha256_init_func: *const fn (ctx: *?*anyopaque, key: [*]const u8, key_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    hmac_sha256_update_func: *const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    hmac_sha256_final_func: *const fn (ctx: ?*anyopaque, output: *?*signal_buffer, user_data: ?*anyopaque) callconv(.c) c_int,
    hmac_sha256_cleanup_func: *const fn (ctx: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void,
    sha512_digest_init_func: *const fn (ctx: *?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int,
    sha512_digest_update_func: *const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    sha512_digest_final_func: *const fn (ctx: ?*anyopaque, output: *?*signal_buffer, user_data: ?*anyopaque) callconv(.c) c_int,
    sha512_digest_cleanup_func: *const fn (ctx: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void,
    encrypt_func: *const fn (output: *?*signal_buffer, cipher: c_int, key: [*]const u8, key_len: usize, iv: [*]const u8, iv_len: usize, plaintext: [*]const u8, plaintext_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    decrypt_func: *const fn (output: *?*signal_buffer, cipher: c_int, key: [*]const u8, key_len: usize, iv: [*]const u8, iv_len: usize, ciphertext: [*]const u8, ciphertext_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    user_data: ?*anyopaque,
};

pub const session_store = extern struct {
    load_session_func: *const fn (record: *?*signal_buffer, user_record: *?*signal_buffer, address: *const signal_protocol_address, user_data: ?*anyopaque) callconv(.c) c_int,
    get_sub_device_sessions_func: *const fn (sessions: *?*signal_int_list, name: [*]const u8, name_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    store_session_func: *const fn (address: *const signal_protocol_address, record: [*]u8, record_len: usize, user_record: ?[*]u8, user_record_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    contains_session_func: *const fn (address: *const signal_protocol_address, user_data: ?*anyopaque) callconv(.c) c_int,
    delete_session_func: *const fn (address: *const signal_protocol_address, user_data: ?*anyopaque) callconv(.c) c_int,
    delete_all_sessions_func: *const fn (name: [*]const u8, name_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    destroy_func: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

pub const pre_key_store = extern struct {
    load_pre_key: *const fn (record: *?*signal_buffer, id: u32, user_data: ?*anyopaque) callconv(.c) c_int,
    store_pre_key: *const fn (id: u32, record: [*]u8, record_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    contains_pre_key: *const fn (id: u32, user_data: ?*anyopaque) callconv(.c) c_int,
    remove_pre_key: *const fn (id: u32, user_data: ?*anyopaque) callconv(.c) c_int,
    destroy_func: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

pub const signed_pre_key_store = extern struct {
    load_signed_pre_key: *const fn (record: *?*signal_buffer, id: u32, user_data: ?*anyopaque) callconv(.c) c_int,
    store_signed_pre_key: *const fn (id: u32, record: [*]u8, record_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    contains_signed_pre_key: *const fn (id: u32, user_data: ?*anyopaque) callconv(.c) c_int,
    remove_signed_pre_key: *const fn (id: u32, user_data: ?*anyopaque) callconv(.c) c_int,
    destroy_func: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

pub const identity_key_store = extern struct {
    get_identity_key_pair: *const fn (public_data: *?*signal_buffer, private_data: *?*signal_buffer, user_data: ?*anyopaque) callconv(.c) c_int,
    get_local_registration_id: *const fn (user_data: ?*anyopaque, registration_id: *u32) callconv(.c) c_int,
    save_identity: *const fn (address: *const signal_protocol_address, key_data: ?[*]u8, key_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    is_trusted_identity: *const fn (address: *const signal_protocol_address, key_data: [*]u8, key_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    destroy_func: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

pub const sender_key_store = extern struct {
    store_sender_key: *const fn (name: *const sender_key_name, record: [*]u8, record_len: usize, user_record: ?[*]u8, user_record_len: usize, user_data: ?*anyopaque) callconv(.c) c_int,
    load_sender_key: *const fn (record: *?*signal_buffer, user_record: *?*signal_buffer, name: *const sender_key_name, user_data: ?*anyopaque) callconv(.c) c_int,
    destroy_func: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

pub extern fn signal_type_unref(instance: *anyopaque) void;

pub extern fn signal_buffer_create(data: [*]const u8, len: usize) ?*signal_buffer;
pub extern fn signal_buffer_data(buffer: *signal_buffer) [*]u8;
pub extern fn signal_buffer_len(buffer: *const signal_buffer) usize;
pub extern fn signal_buffer_free(buffer: ?*signal_buffer) void;
pub extern fn signal_buffer_bzero_free(buffer: ?*signal_buffer) void;

pub extern fn signal_int_list_alloc() ?*signal_int_list;
pub extern fn signal_int_list_push_back(list: *signal_int_list, value: c_int) c_int;

pub extern fn signal_context_create(context: *?*signal_context, user_data: ?*anyopaque) c_int;
pub extern fn signal_context_set_crypto_provider(context: *signal_context, provider: *const signal_crypto_provider) c_int;
pub extern fn signal_context_set_locking_functions(context: *signal_context, lock: *const fn (?*anyopaque) callconv(.c) void, unlock: *const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn signal_context_set_log_function(context: *signal_context, log: *const fn (level: c_int, message: [*]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) void) c_int;
pub extern fn signal_context_destroy(context: *signal_context) void;

pub extern fn signal_protocol_store_context_create(context: *?*signal_protocol_store_context, global: *signal_context) c_int;
pub extern fn signal_protocol_store_context_set_session_store(context: *signal_protocol_store_context, store: *const session_store) c_int;
pub extern fn signal_protocol_store_context_set_pre_key_store(context: *signal_protocol_store_context, store: *const pre_key_store) c_int;
pub extern fn signal_protocol_store_context_set_signed_pre_key_store(context: *signal_protocol_store_context, store: *const signed_pre_key_store) c_int;
pub extern fn signal_protocol_store_context_set_identity_key_store(context: *signal_protocol_store_context, store: *const identity_key_store) c_int;
pub extern fn signal_protocol_store_context_set_sender_key_store(context: *signal_protocol_store_context, store: *const sender_key_store) c_int;
pub extern fn signal_protocol_store_context_destroy(context: *signal_protocol_store_context) void;
pub extern fn signal_protocol_session_contains_session(context: *signal_protocol_store_context, address: *const signal_protocol_address) c_int;

pub extern fn signal_protocol_key_helper_generate_identity_key_pair(key_pair: *?*ratchet_identity_key_pair, global: *signal_context) c_int;
pub extern fn signal_protocol_key_helper_generate_registration_id(registration_id: *u32, extended_range: c_int, global: *signal_context) c_int;
pub extern fn signal_protocol_key_helper_generate_pre_keys(head: *?*pre_key_list_node, start: c_uint, count: c_uint, global: *signal_context) c_int;
pub extern fn signal_protocol_key_helper_key_list_element(node: *const pre_key_list_node) *session_pre_key;
pub extern fn signal_protocol_key_helper_key_list_next(node: *const pre_key_list_node) ?*pre_key_list_node;
pub extern fn signal_protocol_key_helper_key_list_free(head: ?*pre_key_list_node) void;
pub extern fn signal_protocol_key_helper_generate_signed_pre_key(signed_pre_key: *?*session_signed_pre_key, identity: *const ratchet_identity_key_pair, id: u32, timestamp: u64, global: *signal_context) c_int;

pub extern fn ratchet_identity_key_pair_get_public(key_pair: *const ratchet_identity_key_pair) *ec_public_key;
pub extern fn ratchet_identity_key_pair_get_private(key_pair: *const ratchet_identity_key_pair) *ec_private_key;
pub extern fn ratchet_identity_key_pair_create(key_pair: *?*ratchet_identity_key_pair, public_key: *ec_public_key, private_key: *ec_private_key) c_int;

pub extern fn ec_public_key_serialize(buffer: *?*signal_buffer, key: *const ec_public_key) c_int;
pub extern fn ec_private_key_serialize(buffer: *?*signal_buffer, key: *const ec_private_key) c_int;
pub extern fn curve_decode_point(public_key: *?*ec_public_key, data: [*]const u8, len: usize, global: *signal_context) c_int;
pub extern fn curve_decode_private_point(private_key: *?*ec_private_key, data: [*]const u8, len: usize, global: *signal_context) c_int;

pub extern fn session_pre_key_serialize(buffer: *?*signal_buffer, pre_key: *const session_pre_key) c_int;
pub extern fn session_pre_key_deserialize(pre_key: *?*session_pre_key, data: [*]const u8, len: usize, global: *signal_context) c_int;
pub extern fn session_pre_key_get_id(pre_key: *const session_pre_key) u32;
pub extern fn session_pre_key_get_key_pair(pre_key: *const session_pre_key) *ec_key_pair;
pub extern fn session_signed_pre_key_serialize(buffer: *?*signal_buffer, pre_key: *const session_signed_pre_key) c_int;
pub extern fn session_signed_pre_key_deserialize(pre_key: *?*session_signed_pre_key, data: [*]const u8, len: usize, global: *signal_context) c_int;
pub extern fn session_signed_pre_key_get_id(pre_key: *const session_signed_pre_key) u32;
pub extern fn session_signed_pre_key_get_key_pair(pre_key: *const session_signed_pre_key) *ec_key_pair;
pub extern fn session_signed_pre_key_get_signature(pre_key: *const session_signed_pre_key) [*]const u8;
pub extern fn session_signed_pre_key_get_signature_len(pre_key: *const session_signed_pre_key) usize;
pub extern fn ec_key_pair_get_public(key_pair: *const ec_key_pair) *ec_public_key;

pub extern fn session_pre_key_bundle_create(
    bundle: *?*session_pre_key_bundle,
    registration_id: u32,
    device_id: c_int,
    pre_key_id: u32,
    pre_key_public: ?*ec_public_key,
    signed_pre_key_id: u32,
    signed_pre_key_public: *ec_public_key,
    signature: [*]const u8,
    signature_len: usize,
    identity_key: *ec_public_key,
) c_int;

pub extern fn session_builder_create(builder: *?*session_builder, store: *signal_protocol_store_context, address: *const signal_protocol_address, global: *signal_context) c_int;
pub extern fn session_builder_process_pre_key_bundle(builder: *session_builder, bundle: *session_pre_key_bundle) c_int;
pub extern fn session_builder_free(builder: *session_builder) void;

pub extern fn session_cipher_create(cipher: *?*session_cipher, store: *signal_protocol_store_context, address: *const signal_protocol_address, global: *signal_context) c_int;
pub extern fn session_cipher_encrypt(cipher: *session_cipher, padded: [*]const u8, len: usize, encrypted: *?*ciphertext_message) c_int;
pub extern fn session_cipher_decrypt_pre_key_signal_message(cipher: *session_cipher, ciphertext: *pre_key_signal_message, decrypt_context: ?*anyopaque, plaintext: *?*signal_buffer) c_int;
pub extern fn session_cipher_decrypt_signal_message(cipher: *session_cipher, ciphertext: *signal_message, decrypt_context: ?*anyopaque, plaintext: *?*signal_buffer) c_int;
pub extern fn session_cipher_free(cipher: *session_cipher) void;

pub extern fn ciphertext_message_get_type(message: *const ciphertext_message) c_int;
pub extern fn ciphertext_message_get_serialized(message: *const ciphertext_message) *signal_buffer;
pub extern fn signal_message_deserialize(message: *?*signal_message, data: [*]const u8, len: usize, global: *signal_context) c_int;
pub extern fn pre_key_signal_message_deserialize(message: *?*pre_key_signal_message, data: [*]const u8, len: usize, global: *signal_context) c_int;

pub fn unref(p: anytype) void {
    signal_type_unref(@ptrCast(p));
}

/// Copies a signal buffer's bytes into Zig memory and frees it.
pub fn takeBuffer(allocator: @import("std").mem.Allocator, buf: *signal_buffer) ![]u8 {
    defer signal_buffer_bzero_free(buf);
    return allocator.dupe(u8, signal_buffer_data(buf)[0..signal_buffer_len(buf)]);
}
