app [
	main!,
	provide_u8x16,
	provide_i8x16,
	provide_u16x8,
	provide_i16x8,
	provide_u32x4,
	provide_i32x4,
	provide_u64x2,
	provide_i64x2,
	provide_vector_record,
	provide_vector_quad,
	provide_vector_hva,
	provide_vector_wrapper,
	provide_vector_tuple,
	provide_vector_tag,
	make_vector_tag,
	provide_exhaust_registers,
] { pf: platform "./main.roc" }

import pf.Probe exposing [LayoutProbe]

main! = || {
	bits_a = 0x00112233445566778899AABBCCDDEEFF
	bits_b = 0xFFEEDDCCBBAA99887766554433221100

	u8x16 = U8x16.from_u128_bits(bits_a)
	i8x16 = I8x16.from_u128_bits(bits_b)
	u16x8 = U16x8.from_u128_bits(bits_b)
	i16x8 = I16x8.from_u128_bits(bits_a)
	u32x4 = U32x4.from_u128_bits(bits_a)
	i32x4 = I32x4.from_u128_bits(bits_b)
	u64x2 = U64x2.from_u128_bits(bits_b)
	i64x2 = I64x2.from_u128_bits(bits_a)

	u8x16_back = Probe.roundtrip_u8x16!(u8x16)
	i8x16_back = Probe.roundtrip_i8x16!(i8x16)
	u16x8_back = Probe.roundtrip_u16x8!(u16x8)
	i16x8_back = Probe.roundtrip_i16x8!(i16x8)
	u32x4_back = Probe.roundtrip_u32x4!(u32x4)
	i32x4_back = Probe.roundtrip_i32x4!(i32x4)
	u64x2_back = Probe.roundtrip_u64x2!(u64x2)
	i64x2_back = Probe.roundtrip_i64x2!(i64x2)
	expect u8x16_back.to_u128_bits() == bits_a
	expect i8x16_back.to_u128_bits() == bits_b
	expect u16x8_back.to_u128_bits() == bits_b
	expect i16x8_back.to_u128_bits() == bits_a
	expect u32x4_back.to_u128_bits() == bits_a
	expect i32x4_back.to_u128_bits() == bits_b
	expect u64x2_back.to_u128_bits() == bits_b
	expect i64x2_back.to_u128_bits() == bits_a

	vector_record = { before: 0x1020304050607080, bytes: u8x16, words: i32x4, after: 0xA0B0C0D0 }
	vector_record_back = Probe.roundtrip_vector_record!(vector_record)
	expect vector_record_back.before == vector_record.before
	expect vector_record_back.bytes.to_u128_bits() == bits_a
	expect vector_record_back.words.to_u128_bits() == bits_b
	expect vector_record_back.after == vector_record.after

	vector_quad = { a: u8x16, b: i16x8, c: u32x4, d: i64x2 }
	vector_quad_back = Probe.roundtrip_vector_quad!(vector_quad)
	expect vector_quad_back.a.to_u128_bits() == bits_a
	expect vector_quad_back.b.to_u128_bits() == bits_a
	expect vector_quad_back.c.to_u128_bits() == bits_a
	expect vector_quad_back.d.to_u128_bits() == bits_a

	vector_hva = { a: u8x16, b: u8x16, c: u8x16, d: u8x16 }
	vector_hva_back = Probe.roundtrip_vector_hva!(vector_hva)
	expect vector_hva_back.a.to_u128_bits() == bits_a
	expect vector_hva_back.b.to_u128_bits() == bits_a
	expect vector_hva_back.c.to_u128_bits() == bits_a
	expect vector_hva_back.d.to_u128_bits() == bits_a

	vector_wrapper = { only: u8x16 }
	vector_wrapper_back = Probe.roundtrip_vector_wrapper!(vector_wrapper)
	expect vector_wrapper_back.only.to_u128_bits() == bits_a

	vector_tuple = (0x1020304050607080.U64, u8x16, i16x8)
	vector_tuple_back = Probe.roundtrip_vector_tuple!(vector_tuple)
	expect vector_tuple_back.0 == vector_tuple.0
	expect vector_tuple_back.1.to_u128_bits() == bits_a
	expect vector_tuple_back.2.to_u128_bits() == bits_a

	vector_tag = Pair(0x1020304050607080, i16x8)
	vector_tag_back = Probe.roundtrip_vector_tag!(vector_tag)
	expect
		match vector_tag_back {
			Pair(number, vector) => number == 0x1020304050607080 and vector.to_u128_bits() == bits_a
			_ => False
		}

	exhausted = Probe.exhaust_registers!(1, 2, 3, 4, 5, 6, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, u8x16)
	expect exhausted.to_u128_bits() == bits_a

	wide = Wide({
		label: "layout-wide",
		a: Box.box(1),
		b: Box.box(2),
		c: Box.box(3),
		d: Box.box(4),
		e: Box.box(5),
		f: Box.box(6),
		g: Box.box(7),
		h: Box.box(8),
	})
	wide_back = Probe.roundtrip!(wide)
	expect
		match wide_back {
			Wide(payload) => payload.label == "layout-wide"
			_ => False
		}

	aligned_back = Probe.roundtrip!(Aligned({ marker: 99, token: Box.box(123), flag: 7, tiny: 3 }))
	expect
		match aligned_back {
			Aligned(payload) => payload.marker == 99 and payload.flag == 7 and payload.tiny == 3
			_ => False
		}

	empty_back = Probe.roundtrip!(Empty)
	expect
		match empty_back {
			Empty => True
			_ => False
		}

	{}
}

provide_u8x16 = |value| value

provide_i8x16 = |value| value

provide_u16x8 = |value| value

provide_i16x8 = |value| value

provide_u32x4 = |value| value

provide_i32x4 = |value| value

provide_u64x2 = |value| value

provide_i64x2 = |value| value

provide_vector_record = |value| value

provide_vector_quad = |value| value

provide_vector_hva = |value| value

provide_vector_wrapper = |value| value

provide_vector_tuple = |value| value

provide_vector_tag = |value| value

make_vector_tag = |_| Pair(0x1020304050607080, I16x8.from_u128_bits(0x00112233445566778899AABBCCDDEEFF))

provide_exhaust_registers = |_, _, _, _, _, _, _, _, _, _, _, _, _, _, value| value
