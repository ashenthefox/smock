// Messages decoded into canonical ProtoJSON through the public interface,
// beside smock's decoded form: for each field type and each well-known
// type. The messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh), or records written by hand, so the
// codec is never checked against itself. protobuf's conformance suite
// checks the same printer against protobuf's own.

///|
/// `input` decoded as a message of the type whose full name is `name` in
/// the set the script wrote in `hex`, as canonical ProtoJSON text, or the
/// error that stops it.
fn canonical(hex : String, name : String, input : Bytes) -> String {
  let set = hex_set(hex)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  @utf8.decode(@protobuf.decode_canonical_json(set, message, input[:])) catch {
    err => "error: \{err}"
  }
}

///|
/// The set of `message User { int64 id = 1; string name = 2; }`, in
/// package `demo` of a proto3 file, as protoc writes it, in hex.
let user_set : String = "0a430a07612e70726f746f120464656d6f222a0a0455736572120e0a0269641801200128035202696412120a046e616d6518022001280952046e616d65620670726f746f33"

///|
test "the ticket's example: a 64-bit integer as a string, and a field at its default left out" {
  // id: 42, and no name.
  let user = b"\x08\x2a"
  inspect(
    canonical(user_set, "demo.User", user),
    content=(
      #|{"id":"42"}
    ),
  )
  inspect(
    decoded(user_set, "demo.User", user),
    content=(
      #|{"id":42,"name":""}
    ),
  )
}

///|
test "each scalar type: 64-bit integers as strings, at their largest and smallest values" {
  inspect(
    canonical(scalars_set, "scalars.Every", fixture(every_max)),
    content=(
      #|{"aDouble":1.7976931348623157e+308,"aFloat":3.4028235e+38,"anInt64":"9223372036854775807","aUint64":"18446744073709551615","anInt32":2147483647,"aFixed64":"18446744073709551615","aFixed32":4294967295,"aBool":true,"aString":"Kyōto \"quoted\"\n","aBytes":"AAH7/w==","aUint32":4294967295,"anSfixed32":2147483647,"anSfixed64":"9223372036854775807","anSint32":2147483647,"anSint64":"9223372036854775807","aStatus":"ACTIVE"}
    ),
  )
  // The unsigned types, the bool, the string and the enum at their
  // defaults are left out.
  inspect(
    canonical(scalars_set, "scalars.Every", fixture(every_min)),
    content=(
      #|{"aDouble":-1.7976931348623157e+308,"aFloat":-3.4028235e+38,"anInt64":"-9223372036854775808","anInt32":-2147483648,"aBytes":"YQ==","anSfixed32":-2147483648,"anSfixed64":"-9223372036854775808","anSint32":-2147483648,"anSint64":"-9223372036854775808"}
    ),
  )
}

///|
test "fields without presence are left out at their defaults, even when the message holds them; fields with presence are printed whenever it does" {
  inspect(canonical(scalars_set, "scalars.Every", b""), content="{}")
  // Records of a double, an int32 whose varint's low 32 bits are 0, a
  // string, bytes, an enum and a bool, each at its default.
  let defaults = b"\x09\x00\x00\x00\x00\x00\x00\x00\x00\x28\x80\x80\x80\x80\x10\x4a\x00\x62\x00\xa0\x01\x00\x40\x00"
  inspect(canonical(scalars_set, "scalars.Every", defaults), content="{}")
  // A bool whose varint is 2, and an int64 past 32 bits.
  inspect(
    canonical(scalars_set, "scalars.Every", b"\x40\x02\x18\x80\x80\x80\x80\x10"),
    content=(
      #|{"anInt64":"4294967296","aBool":true}
    ),
  )
  // The nested message and the two optional fields set, each at its
  // default.
  let message = nested(w => {
    message_field(w, 21, b"")
    varint_field(w, 22, 0)
    string_field(w, 23, "")
  })
  inspect(
    canonical(scalars_set, "scalars.Every", message),
    content=(
      #|{"anAddress":{},"maybeCount":0,"maybeName":""}
    ),
  )
}

///|
test "a double or a float of negative zero is -0, not a default; other numbers print as in the decoded form" {
  inspect(
    canonical(
      scalars_set, "scalars.Every", b"\x09\x00\x00\x00\x00\x00\x00\x00\x80\x15\x00\x00\x00\x80",
    ),
    content=(
      #|{"aDouble":-0,"aFloat":-0}
    ),
  )
  let floats = [0.1, 9.99, 16777217.0, 1.0e-7, 1.0e21, -2.5].map(value => {
    let message = nested(w => {
      w.tag(2, I32)
      w.fixed32(Float::from_double(value).reinterpret_as_uint())
    })
    canonical(scalars_set, "scalars.Every", message)
  })
  inspect(
    floats.join(" "),
    content=(
      #|{"aFloat":0.1} {"aFloat":9.99} {"aFloat":16777216} {"aFloat":1e-7} {"aFloat":1e+21} {"aFloat":-2.5}
    ),
  )
  let specials = [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0].map(value => {
    let message = nested(w => {
      w.tag(1, I64)
      w.fixed64(value.reinterpret_as_uint64())
    })
    canonical(scalars_set, "scalars.Every", message)
  })
  inspect(
    specials.join(" "),
    content=(
      #|{"aDouble":"NaN"} {"aDouble":"Infinity"} {"aDouble":"-Infinity"}
    ),
  )
}

///|
test "repeated fields and maps: 64-bit elements as strings, map keys as in the decoded form" {
  inspect(
    canonical(replies_set, "replies.Everything", fixture(everything_lists)),
    content=(
      #|{"int32s":[1,-1,300],"unpackedInt32s":[1,-2],"doubles":[0.5,1e+100],"floats":[0.1,9.99],"int64s":["9223372036854775807","-1"],"uint64s":["18446744073709551615","0"],"sint32s":[-1,1,-2147483648],"sint64s":["-9223372036854775808"],"fixed32s":[1,4294967295],"sfixed64s":["-1"],"bools":[true,false,true],"statuses":["ACTIVE","STATUS_UNSPECIFIED","SUSPENDED",7],"strings":["","x"],"byteStrings":["/w==",""],"nesteds":[{"label":"a"},{}]}
    ),
  )
  // Map entries in key order, as `decode_json` prints them.
  inspect(
    canonical(replies_set, "replies.Everything", fixture(everything_maps)),
    content=(
      #|{"counts":{"":0,"a":1,"b":2},"names":{"-1":"minus one","2":"","10":"ten"},"byFlag":{"false":{},"true":{"label":"yes"}},"byId":{"-9223372036854775808":"ACTIVE","7":"STATUS_UNSPECIFIED"},"blobs":{"18446744073709551615":"AQ=="},"bySint":{"-2":1.5},"byFixed":{"1":true}}
    ),
  )
  inspect(
    canonical(collections_set, "collections.Tagged", fixture(tagged)),
    content=(
      #|{"tags":["a","b"],"counts":{"1":3,"2":5,"10":1}}
    ),
  )
}

///|
test "a repeated field or a map that holds no element is left out, a packed record of no values and numbers a closed enum does not define included" {
  // A packed record of no values.
  inspect(
    canonical(replies_set, "replies.Everything", b"\xa2\x01\x00"),
    content="{}",
  )
  inspect(
    decoded(replies_set, "replies.Everything", b"\xa2\x01\x00").contains(
      "\"int32s\":[]",
    ),
    content="true",
  )
  // A proto2 Parcel whose history holds only 9, and whose map states only
  // the entry "b": 9, which State does not define, and whose sizes come
  // as a packed record of no values.
  inspect(
    canonical(
      shipping_set, "shipping.Parcel", b"\x12\x01\x09\x3a\x05\x0a\x01\x62\x10\x09\x22\x00",
    ),
    content="{}",
  )
  // The same, with SHIPPED after the 9, and the entry "a": DELIVERED.
  inspect(
    canonical(
      shipping_set, "shipping.Parcel", b"\x12\x02\x09\x01\x3a\x05\x0a\x01\x62\x10\x09\x3a\x05\x0a\x01\x61\x10\x02",
    ),
    content=(
      #|{"history":["SHIPPED"],"states":{"a":"DELIVERED"}}
    ),
  )
  // A oneof member and a proto3 optional field at their defaults, and an
  // empty message, are printed.
  inspect(
    canonical(replies_set, "replies.Everything", fixture(everything_choice)),
    content=(
      #|{"nested":{},"maybe":0,"word":""}
    ),
  )
}
