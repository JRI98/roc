//! Wasm-level signatures for builtin wrapper calls.
//!
//! The ABI is per wrapper. Codegen must push the exact params listed here and
//! then emit a relocation to the listed `roc_builtins_*` symbol.

const std = @import("std");
const Allocator = std.mem.Allocator;
const WasmModule = @import("WasmModule.zig");
const SymbolIndex = @import("index_types.zig").SymbolIndex;

/// Wasm value type used in builtin wrapper signatures.
pub const ValType = WasmModule.ValType;

/// Builtin wrapper known to wasm codegen.
pub const BuiltinKind = enum {
    dec_mul,
    dec_div,
    dec_div_trunc,
    dec_to_str,
    i128_div_s,
    i128_mod_s,
    u128_div,
    u128_mod,
    num_mul_with_overflow_i128,
    num_mul_with_overflow_u128,
    i128_to_dec,
    u128_to_dec,
    dec_to_int_try_unsafe,
    dec_to_f32,
    float_to_str,
    float_pow,
    float_sin,
    float_cos,
    float_tan,
    float_asin,
    float_acos,
    float_atan,
    int_to_str,
    int_from_str,
    dec_from_str,
    float_from_str,
    str_equal,
    str_concat,
    str_repeat,
    str_trim,
    str_trim_start,
    str_trim_end,
    str_split,
    str_join_with,
    str_reserve,
    str_release_excess_capacity,
    str_with_capacity,
    str_drop_prefix,
    str_drop_prefix_caseless_ascii,
    str_drop_suffix,
    str_with_ascii_lowercased,
    str_with_ascii_uppercased,
    str_caseless_ascii_equals,
    str_escape_and_quote,
    str_from_utf8,
    list_append_unsafe,
    list_concat,
    list_drop_at,
    list_reserve,
    list_replace,
    list_swap,
    list_eq,
    list_str_eq,
    list_list_eq,
    list_reverse,
    allocate_with_refcount,
    i8_mod_by,
    u8_mod_by,
    i16_mod_by,
    u16_mod_by,
    i32_mod_by,
    u32_mod_by,
    i64_mod_by,
    u64_mod_by,
    dict_pseudo_seed,
    hasher_finish,
    hasher_write_u64,
    hasher_write_u128,
    hasher_write_f32_bits,
    hasher_write_f64_bits,
    hasher_write_bytes,
    hasher_write_str,
    crypto_sha256_hash_bytes,
    crypto_sha256_hasher_empty,
    crypto_sha256_hasher_write,
    crypto_sha256_hasher_finish,
    crypto_blake3_hash_bytes,
    crypto_blake3_hasher_empty,
    crypto_blake3_hasher_write,
    crypto_blake3_hasher_finish,
};

/// Wasm call signature and symbol name for a builtin wrapper.
pub const Sig = struct {
    name: []const u8,
    wasm_params: []const ValType,
    wasm_results: []const ValType,
    takes_roc_ops: bool,
};

/// Builtin signatures indexed by `BuiltinKind`.
pub const sigs: [@typeInfo(BuiltinKind).@"enum".fields.len]Sig = .{
    .{ .name = "roc_builtins_dec_mul", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_dec_div", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_dec_div_trunc", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_dec_to_str", .wasm_params = &.{ .i32, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_num_div_trunc_i128", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_num_rem_trunc_i128", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_num_div_trunc_u128", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_num_rem_trunc_u128", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_num_mul_with_overflow_i128", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_num_mul_with_overflow_u128", .wasm_params = &.{ .i32, .i32, .i64, .i64, .i64, .i64 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_i128_to_dec_try_unsafe", .wasm_params = &.{ .i32, .i64, .i64, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_u128_to_dec_try_unsafe", .wasm_params = &.{ .i32, .i64, .i64, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_dec_to_int_try_unsafe", .wasm_params = &.{ .i32, .i64, .i64, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_dec_to_f32_try_unsafe", .wasm_params = &.{ .i32, .i64, .i64, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_to_str", .wasm_params = &.{ .i32, .i64, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_float_pow", .wasm_params = &.{ .f64, .f64, .i32 }, .wasm_results = &.{.f64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_sin", .wasm_params = &.{ .f64, .i32 }, .wasm_results = &.{.f64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_cos", .wasm_params = &.{ .f64, .i32 }, .wasm_results = &.{.f64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_tan", .wasm_params = &.{ .f64, .i32 }, .wasm_results = &.{.f64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_asin", .wasm_params = &.{ .f64, .i32 }, .wasm_results = &.{.f64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_acos", .wasm_params = &.{ .f64, .i32 }, .wasm_results = &.{.f64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_atan", .wasm_params = &.{ .f64, .i32 }, .wasm_results = &.{.f64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_int_to_str", .wasm_params = &.{ .i32, .i64, .i64, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_int_from_str", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_dec_from_str", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_float_from_str", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_str_equal", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_str_concat", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_repeat", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_trim", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_trim_start", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_trim_end", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_split", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_join_with", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_reserve", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i64, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_release_excess_capacity", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_with_capacity", .wasm_params = &.{ .i32, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_drop_prefix", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_drop_prefix_caseless_ascii", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_drop_suffix", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_with_ascii_lowercased", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_with_ascii_uppercased", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_caseless_ascii_equals", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_str_escape_and_quote", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_str_from_utf8", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_list_append_unsafe", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_list_concat", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i64, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_list_drop_at", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i64, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_list_reserve", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i64, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_list_replace", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i64, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_list_swap", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i64, .i64, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_list_eq", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_list_str_eq", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_list_list_eq", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_list_reverse", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_allocate_with_refcount", .wasm_params = &.{ .i32, .i32, .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_i8_mod_by", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_u8_mod_by", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_i16_mod_by", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_u16_mod_by", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_i32_mod_by", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_u32_mod_by", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{.i32}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_i64_mod_by", .wasm_params = &.{ .i64, .i64 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_u64_mod_by", .wasm_params = &.{ .i64, .i64 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_dict_pseudo_seed", .wasm_params = &.{}, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_hasher_finish", .wasm_params = &.{.i64}, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_hasher_write_u64", .wasm_params = &.{ .i64, .i32, .i64, .i32 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_hasher_write_u128", .wasm_params = &.{ .i64, .i32, .i64, .i64 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_hasher_write_f32_bits", .wasm_params = &.{ .i64, .i64 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_hasher_write_f64_bits", .wasm_params = &.{ .i64, .i64 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_hasher_write_bytes", .wasm_params = &.{ .i64, .i32, .i32, .i32 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_hasher_write_str", .wasm_params = &.{ .i64, .i32, .i32, .i32 }, .wasm_results = &.{.i64}, .takes_roc_ops = false },
    .{ .name = "roc_builtins_crypto_sha256_hash_bytes", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_crypto_sha256_hasher_empty", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_crypto_sha256_hasher_write", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_crypto_sha256_hasher_finish", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_crypto_blake3_hash_bytes", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_crypto_blake3_hasher_empty", .wasm_params = &.{ .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_crypto_blake3_hasher_write", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
    .{ .name = "roc_builtins_crypto_blake3_hasher_finish", .wasm_params = &.{ .i32, .i32, .i32, .i32, .i32 }, .wasm_results = &.{}, .takes_roc_ops = true },
};

/// Return the builtin wrapper signature for `kind`.
pub fn sigOf(kind: BuiltinKind) Sig {
    return sigs[@intFromEnum(kind)];
}

/// Relocation symbol table indexed by builtin kind.
pub const SymbolTable = std.enums.EnumArray(BuiltinKind, SymbolIndex);

/// Declare every builtin wrapper as an undefined function symbol in a generated
/// relocatable wasm object.
pub fn declareUndefinedRelocs(module: *WasmModule) Allocator.Error!SymbolTable {
    var result = SymbolTable.initUndefined();
    inline for (std.meta.tags(BuiltinKind)) |kind| {
        const sig = sigOf(kind);
        const type_idx = try module.addFuncType(sig.wasm_params, sig.wasm_results);
        const imported = try module.addFunctionImportWithSymbol("env", sig.name, type_idx);
        result.set(kind, imported.symbol);
    }
    return result;
}

/// Locate builtin function symbols in a merged wasm module.
pub fn populateForRelocs(module: *const WasmModule) WasmModule.SymbolLookupError!SymbolTable {
    var result = SymbolTable.initUndefined();
    inline for (std.meta.tags(BuiltinKind)) |kind| {
        result.set(kind, try module.findDefinedFunctionSymbolExact(sigOf(kind).name));
    }
    return result;
}

/// The wasm32 `ValType` a single wrapper parameter or return type lowers to.
///
/// wasm32 lowering rules (each Zig scalar/pointer maps to exactly one ValType,
/// because the wrappers already decompose 128-bit values into two `u64`s and pass
/// `RocStr`/`RocList` by pointer):
/// - `usize`/`isize` and every pointer are 32-bit on wasm32 → `.i32`
/// - `bool`, enums, and integers up to 32 bits → `.i32`
/// - 64-bit integers → `.i64`
/// - `f32` → `.f32`, `f64` → `.f64`
///
/// Any other shape (a by-value aggregate, a >64-bit integer, a non-pointer
/// optional) is a compile error, so a newly added wrapper cannot silently bypass
/// verification.
fn wasmValTypeOf(comptime T: type) ValType {
    // On wasm32 `usize`/`isize` are 32-bit even though the verifier itself is
    // compiled for a 64-bit host (`usize` and `u64` are distinct types, so this
    // check does not also catch genuine `u64` params).
    if (T == usize or T == isize) return .i32;
    return switch (@typeInfo(T)) {
        .bool => .i32,
        .int => |info| switch (info.bits) {
            0...32 => .i32,
            33...64 => .i64,
            else => @compileError("builtin wrapper integer wider than 64 bits must be decomposed: " ++ @typeName(T)),
        },
        .float => |info| switch (info.bits) {
            32 => .f32,
            64 => .f64,
            else => @compileError("unsupported float width in builtin wrapper: " ++ @typeName(T)),
        },
        .pointer => .i32, // wasm32 pointer
        .optional => |o| if (@typeInfo(o.child) == .pointer) .i32 else @compileError("unsupported optional (non-pointer) builtin wrapper type: " ++ @typeName(T)),
        .@"enum" => |info| wasmValTypeOf(info.tag_type),
        else => @compileError("unsupported builtin wrapper type: " ++ @typeName(T)),
    };
}

// Pin every `sigs` row to the real Zig wrapper signature it names.
//
// Each row's `.name` is the pub wrapper function in `builtins.dev_wrappers`; a
// wrong ValType, arity, result, or `takes_roc_ops` flag is silent stack
// corruption at runtime, so this comptime block re-derives the whole wasm ABI
// from `@typeInfo` of the wrapper and asserts it matches the hand-written row.
//
// Row-to-wrapper mapping: `@field(dev_wrappers, row.name)`. Every row must
// resolve to a wrapper — the `@hasDecl` guard makes a missing wrapper a compile
// error. There is deliberately no exceptions list: all rows map to a wrapper,
// and if that ever stops holding the guard fails loudly rather than skipping.
comptime {
    @setEvalBranchQuota(100_000);
    const dw = @import("builtins").dev_wrappers;
    const RocOps = @import("builtins").host_abi.RocOps;
    for (sigs) |sig| {
        if (!@hasDecl(dw, sig.name)) @compileError("missing dev wrapper: " ++ sig.name);
        const fn_info = @typeInfo(@TypeOf(@field(dw, sig.name))).@"fn";

        if (fn_info.params.len != sig.wasm_params.len) {
            @compileError("builtin ABI mismatch (" ++ sig.name ++ "): wrapper param count differs from wasm_params length");
        }

        for (fn_info.params, sig.wasm_params, 0..) |param, want, i| {
            const got = wasmValTypeOf(param.type.?);
            if (got != want) {
                @compileError(std.fmt.comptimePrint(
                    "builtin ABI mismatch ({s}): param {d} wrapper lowers to .{s} but sigs row declares .{s}",
                    .{ sig.name, i, @tagName(got), @tagName(want) },
                ));
            }
        }

        const ret = fn_info.return_type.?;
        if (ret == void) {
            if (sig.wasm_results.len != 0) {
                @compileError("builtin ABI mismatch (" ++ sig.name ++ "): wrapper returns void but sigs row lists a result");
            }
        } else {
            if (sig.wasm_results.len != 1) {
                @compileError("builtin ABI mismatch (" ++ sig.name ++ "): wrapper returns a value but sigs row does not list exactly one result");
            }
            const got = wasmValTypeOf(ret);
            if (got != sig.wasm_results[0]) {
                @compileError(std.fmt.comptimePrint(
                    "builtin ABI mismatch ({s}): result wrapper returns .{s} but sigs row declares .{s}",
                    .{ sig.name, @tagName(got), @tagName(sig.wasm_results[0]) },
                ));
            }
        }

        const takes_roc_ops = fn_info.params.len > 0 and blk: {
            const last = fn_info.params[fn_info.params.len - 1].type.?;
            break :blk @typeInfo(last) == .pointer and @typeInfo(last).pointer.child == RocOps;
        };
        if (takes_roc_ops != sig.takes_roc_ops) {
            @compileError("builtin ABI mismatch (" ++ sig.name ++ "): takes_roc_ops flag disagrees with trailing *RocOps param");
        }
    }
}
