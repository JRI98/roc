app [main!] { pf: platform "./static-lib-platform/main.roc" }

string_ops_ok : U64 -> Bool
string_ops_ok = |seed| {
    roc = if seed == 0 { "Roc" } else { "ROc" }
    trimmed = Str.trim("  ${roc}  ")
    trim_start = Str.trim_start("  ${roc}")
    trim_end = Str.trim_end("${roc}  ")
    lower = Str.with_ascii_lowercased(roc)
    upper = Str.with_ascii_uppercased(roc)
    dropped_prefix = Str.drop_prefix("prefix-${roc}", "prefix-")
    dropped_suffix = Str.drop_suffix("${roc}-suffix", "-suffix")
    repeated = Str.repeat(roc, 2)
    reserved = Str.reserve(roc, 8)
    released = Str.release_excess_capacity(reserved)
    capacity = Str.concat(Str.with_capacity(8), roc)
    joined = Str.join_with([roc, "!"], "")
    split = Str.split_on("${roc},x", ",")
    utf8 = if seed == 0 { [82.U8, 111.U8, 99.U8] } else { [82.U8, 79.U8, 99.U8] }
    decoded = Str.from_utf8(utf8)

    found = match Str.find_first("${roc}:lang", ":") {
        Ok({ before, after }) => before == roc and after == "lang"
        Err(_) => False
    }
    caseless_prefix = match Str.drop_prefix_caseless_ascii("Content-${roc}", "content-") {
        Ok(after) => after == roc
        Err(_) => False
    }
    decoded_ok = match decoded {
        Ok(value) => value == roc
        Err(_) => False
    }

    trimmed == roc
        and trim_start == roc
        and trim_end == roc
        and lower == "roc"
        and upper == "ROC"
        and dropped_prefix == roc
        and dropped_suffix == roc
        and repeated == Str.concat(roc, roc)
        and released == roc
        and capacity == roc
        and joined == Str.concat(roc, "!")
        and List.len(split) == 2
        and Str.caseless_ascii_equals(roc, lower)
        and Str.inspect(roc) == Str.concat(Str.concat("\"", roc), "\"")
        and found
        and caseless_prefix
        and decoded_ok
}

numeric_ops_result : U64 -> Str
numeric_ops_result = |seed| {
    int_text = if seed == 0 { "-42" } else { "-43" }
    dec_text = if seed == 0 { "42.5" } else { "43.5" }
    float_text = if seed == 0 { "1.5" } else { "2.5" }
    whole_i128 : I128
    whole_i128 = if seed == 0 { 42 } else { 43 }
    whole_u128 : U128
    whole_u128 = if seed == 0 { 42 } else { 43 }
    whole_dec : Dec
    whole_dec = if seed == 0 { 42.0 } else { 43.0 }
    parsed_i64 = I64.from_str(int_text) == Ok(if seed == 0 { -42 } else { -43 })
    parsed_dec = Dec.from_str(dec_text) == Ok(if seed == 0 { 42.5 } else { 43.5 })
    parsed_f64 = F64.from_str(float_text) == Ok(if seed == 0 { 1.5 } else { 2.5 })

    dec_base : Dec
    dec_base = if seed == 0 { 2.0 } else { 3.0 }
    dec_square : Dec
    dec_square = if seed == 0 { 9.0 } else { 16.0 }
    dec_zero : Dec
    dec_zero = if seed == 0 { 0.0 } else { 0.5 }
    dec_one : Dec
    dec_one = if seed == 0 { 1.0 } else { 0.5 }
    dec_epsilon : Dec
    dec_epsilon = 0.000000000000001
    dec_pow_ok = Dec.pow(dec_base, 3.0) == (if seed == 0 { 8.0 } else { 27.0 })
    dec_sqrt_ok = Dec.sqrt(dec_square) == (if seed == 0 { 3.0 } else { 4.0 })
    dec_sin_ok = seed != 0 or Dec.abs(Dec.sin(dec_zero)) < dec_epsilon
    dec_cos_ok = seed != 0 or Dec.abs(Dec.cos(dec_zero) - 1.0) < dec_epsilon
    dec_tan_ok = seed != 0 or Dec.abs(Dec.tan(dec_zero)) < dec_epsilon
    dec_asin_ok = seed != 0 or Dec.abs(Dec.asin(dec_zero)) < dec_epsilon
    dec_acos_ok = seed != 0 or Dec.abs(Dec.acos(dec_one)) < dec_epsilon
    dec_atan_ok = seed != 0 or Dec.abs(Dec.atan(dec_zero)) < dec_epsilon

    wide_dec : Dec
    wide_dec = if seed == 0 { 42.5 } else { 43.5 }
    wide = Dec.to_i128_try(wide_dec) == Ok(whole_i128)
        and Dec.to_u128_try(wide_dec) == Ok(whole_u128)
        and I128.to_dec_try(whole_i128) == Ok(whole_dec)
        and U128.to_dec_try(whole_u128) == Ok(whole_dec)

    float_base : F64
    float_base = if seed == 0 { 2.0 } else { 3.0 }
    float_zero : F64
    float_zero = if seed == 0 { 0.0 } else { 0.5 }
    float_one : F64
    float_one = if seed == 0 { 1.0 } else { 0.5 }
    float_math = F64.pow(float_base, 3.0) == (if seed == 0 { 8.0 } else { 27.0 })
        and (seed != 0 or F64.sin(float_zero) == 0.0)
        and (seed != 0 or F64.cos(float_zero) == 1.0)
        and (seed != 0 or F64.tan(float_zero) == 0.0)
        and (seed != 0 or F64.asin(float_zero) == 0.0)
        and (seed != 0 or F64.acos(float_one) == 0.0)
        and (seed != 0 or F64.atan(float_zero) == 0.0)

    if !(parsed_i64 and parsed_dec and parsed_f64) {
        "parse"
    } else if !dec_pow_ok {
        "dec-pow"
    } else if !dec_sqrt_ok {
        "dec-sqrt"
    } else if !dec_sin_ok {
        "dec-sin"
    } else if !dec_cos_ok {
        "dec-cos"
    } else if !dec_tan_ok {
        "dec-tan"
    } else if !dec_asin_ok {
        "dec-asin"
    } else if !dec_acos_ok {
        "dec-acos"
    } else if !dec_atan_ok {
        "dec-atan"
    } else if !wide {
        "wide"
    } else if !float_math {
        "float"
    } else {
        "ok"
    }
}

main! = |seed| {
    if !string_ops_ok(seed) {
        "string"
    } else {
        numeric_ops_result(seed)
    }
}
