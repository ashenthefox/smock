// What gRPC's server reflection asks of a Descriptor set, through the
// public interface: each file as the set encodes it, without its source
// info, from sets written octet by octet here, and the file that defines a
// symbol, on the set protoc builds from
// fixtures/protobuf/model/shop/orders.proto (shop_set_test.mbt).

///|
/// The files `files_without_source_info` gives for `set`, in hex, one per
/// line, or the error that stops it.
fn files_of(set : Bytes) -> String {
  try @protobuf.files_without_source_info(set[:]) catch {
    err => "error: \{err}"
  } noraise {
    files => files.iter().map(file => @hex.encode(file)).collect().join("\n")
  }
}

///|
test "each file of a set is given as the set encodes it, in order, without its SourceCodeInfo, field 9, every other field kept byte for byte, unknown ones and options included" {
  // a.proto: its name, its package, a message M whose field 9, a reserved
  // range, stays, empty options, source info, its syntax, then Buf's
  // field 8042.
  let a = b"\x0a\x07a.proto\x12\x01a\x22\x07\x0a\x01M\x4a\x02\x08\x01\x42\x00\x4a\x02\x0a\x00\x62\x06proto3\xd2\xf6\x03\x02\x08\x01"
  // b.proto: its name, empty source info, its dependency, then source info
  // again.
  let b = b"\x0a\x07b.proto\x4a\x00\x1a\x07a.proto\x4a\x02\x0a\x00"
  // The two files, with a field 2 of the set, which is not a file, between
  // them.
  let set = b"\x0a\x29" + a + b"\x10\x01\x0a\x18" + b
  inspect(
    files_of(set),
    content=(
      #|0a07612e70726f746f12016122070a014d4a0208014200620670726f746f33d2f603020801
      #|0a07622e70726f746f1a07612e70726f746f
    ),
  )
}

///|
test "a set without files gives none, and a file of source info alone gives an empty file" {
  inspect(files_of(b""), content="")
  inspect(files_of(b"\x10\x01"), content="")
  inspect(files_of(b"\x0a\x02\x4a\x00\x0a\x00"), content="\n")
}

///|
test "a set that is not protobuf, or whose file is not a length-delimited value of records, is refused" {
  inspect(
    files_of(b"\x0a\x05\x0a\x07a"),
    content="error: octet 1: a length of 5 runs past the end of the input, which has 3 octets left",
  )
  inspect(
    files_of(b"\x08\x01"),
    content="error: octet 0: field 1 has wire type VARINT, not LEN",
  )
  inspect(
    files_of(b"\x0a\x03\x0a\x07a"),
    content="error: octet 3: a length of 7 runs past the end of the input, which has 1 octets left",
  )
  inspect(
    files_of(b"\x0a\x02\x4c\x00"),
    content="error: octet 2: the group of field 9 ends where none started",
  )
}

///|
test "the file that defines a symbol is found for every kind of named element, nested ones included, with enum values in the scope of their enum's parent" {
  let set = shop()
  let out = []
  for
    symbol in [
      // Messages, nested ones, a map's entry type and a group's type.
      "shop.v1.Order", "shop.v1.Order.Line", "shop.v1.Order.LabelsEntry", "shop.Money.Note",
      // Fields, of a message, of a nested message and of a group's type.
       "shop.v1.Order.order_id", "shop.v1.Order.Line.sku", "shop.Money.Note.text",
      // Enums and their values, top-level and nested, an alias included.
       "shop.Status", "shop.ACTIVE", "shop.ENABLED", "shop.v1.Order.Line.Kind", "shop.v1.Order.Line.GOODS",
      // A service and its methods.
       "shop.v1.Orders", "shop.v1.Orders.Get", "shop.v1.Orders.Chat",
      // Extensions, declared at the top level and in a message.
       "shop.priority", "shop.Audit.audited_by",
      // A message of an editions file, and its field.
       "shop.legacy.Item", "shop.legacy.Item.name",
    ] {
    match set.find_file_containing_symbol(symbol) {
      Some(file) => out.push("\{symbol}: \{file.name}")
      None => out.push("\{symbol}: -")
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|shop.v1.Order: shop/orders.proto
      #|shop.v1.Order.Line: shop/orders.proto
      #|shop.v1.Order.LabelsEntry: shop/orders.proto
      #|shop.Money.Note: shop/common.proto
      #|shop.v1.Order.order_id: shop/orders.proto
      #|shop.v1.Order.Line.sku: shop/orders.proto
      #|shop.Money.Note.text: shop/common.proto
      #|shop.Status: shop/common.proto
      #|shop.ACTIVE: shop/common.proto
      #|shop.ENABLED: shop/common.proto
      #|shop.v1.Order.Line.Kind: shop/orders.proto
      #|shop.v1.Order.Line.GOODS: shop/orders.proto
      #|shop.v1.Orders: shop/orders.proto
      #|shop.v1.Orders.Get: shop/orders.proto
      #|shop.v1.Orders.Chat: shop/orders.proto
      #|shop.priority: shop/common.proto
      #|shop.Audit.audited_by: shop/common.proto
      #|shop.legacy.Item: shop/legacy.proto
      #|shop.legacy.Item.name: shop/legacy.proto
    ),
  )
}

///|
test "a name that is not a symbol of the set has no file: a package, a oneof, an enum value inside its enum, a leading dot, a method's path, and names the set lacks" {
  let set = shop()
  let out = []
  for
    symbol in [
      "shop.v1", "shop", "shop.v1.Order.payer", "shop.Status.ACTIVE", ".shop.v1.Order",
      "shop.v1.Orders/Get", "/shop.v1.Orders/Get", "shop.v1.Missing", "shop.v1.Order.missing",
      "shop.v1.Orders.Missing", "shop.v1.Order.", "", "Order",
    ] {
    if set.find_file_containing_symbol(symbol) is Some(file) {
      out.push("\{symbol}: \{file.name}")
    }
  }
  inspect(out.join("\n"), content="")
}
