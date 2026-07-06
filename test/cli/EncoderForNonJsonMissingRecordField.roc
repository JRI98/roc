EncoderForNonJsonMissingRecordField :: [].{}

Format := [Default].{
	rename_field : Format, Str -> Str
	rename_field = |_, name| name

	begin_record : U64 -> Try(U64, [])
	begin_record = |state| Ok(state)

	encode_record_field : Str, U64 -> Try(U64, [])
	encode_record_field = |_, state| Ok(state)

	end_record : U64 -> Try(U64, [])
	end_record = |state| Ok(state)

	encode_str : Str, U64 -> Try(U64, [])
	encode_str = |value, state| Ok(state + Str.count_utf8_bytes(value))
}

encode : value -> Try(U64, [])
	where [
		value.encoder_for : Format -> (value, U64 -> Try(U64, [])),
	]
encode = |value| {
	Shape : value
	encode_value = Shape.encoder_for(Format.Default)
	encode_value(value, 0)
}

main : Try(U64, [])
main = {
	value : { optional : Try(Str, [Missing]) }
	value = { optional: Err(Missing) }

	encode(value)
}
