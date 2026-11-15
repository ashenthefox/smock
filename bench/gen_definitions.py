#!/usr/bin/env python3
"""Writes the release benchmark's definition set, bench/definitions/, its
Scenario variant, bench/definitions-scenarios/, its CRUD variant,
bench/definitions-crud/, with the CRUD variant's request mix,
bench/requests-crud.json, and its gRPC variant, bench/definitions-grpc/,
with the gRPC variant's request mix, bench/requests-grpc.json, and the
bodies of its calls, bench/requests-grpc/.

The set stands in for four services of a shop, each a Mock with its own
Host, with about 1,200 Stubs in all (e2e/bench_test.mbt pins the exact
count). Most Stubs have an exact path, so the match index finds them; a
few have path, query, header or body patterns, or `json` body conditions,
which smock tries in their place in the order:

- catalog (catalog.bench.internal): 600 items by SKU, a search with query
  patterns whose results come from a body file, and two path patterns;
- users (users.bench.internal): 300 profiles that need a bearer token
  (a header pattern), and two path patterns;
- orders (orders.bench.internal): 48 ways to create an order, told apart
  by `json` body conditions, an order by ID (a path pattern) and a status
  update (a path pattern and a body pattern);
- payments (payments.bench.internal), the Default Mock: six currencies to
  pay in (`json` body conditions and a header pattern) and 200 payments by
  ID.

Every Mock keeps its Journal on, as smock does by default. The requests
that bench/bench.py sends are in bench/requests.json; e2e/bench_test.mbt
checks that each one reaches the Stub it names.

The Scenario variant is the same set, but each Stub that a request of the
mix names has a Scenario clause named for the request, which requires
`Started` and moves to `Seen`, and right after it a twin, `<id>-seen`, with
the same request and response, which requires `Seen` and moves back to
`Started`. Each request carries its own Session, so its Scenario is its
own: the two Stubs take turns, and every request of the mix matches one of
them and moves its Scenario, in every Mock. bench/bench.py serves it with
`--definitions bench/definitions-scenarios`; e2e/bench_test.mbt checks that
each request moves its Scenario.

The CRUD variant is the same set, but the catalog's items and the orders
are Data buckets, each served by a CRUD Stub in place of the Stubs that
answered them one by one: `items` (keyed by `sku`, the 600 items that the
item Stubs answered, in their order), through `catalog-items` at
`/catalog/items`, where those Stubs were; and `orders` (keyed by `id`, an
order for each of the 48 ways to create one, the mix's order among them),
through `orders` at `/orders`, right after the Stubs that create an order
and in place of `get-order`. A POST to `/orders` still matches a create
Stub first, so the CRUD Stub never creates. Its request mix,
bench/requests-crud.json, is bench/requests.json, but the catalog search
becomes `catalog-list`, a list query, and the status update becomes
`update-order`, a PATCH of the order: the CRUD Stubs list, read and update
items, and no request creates one. bench/bench.py sends that mix when it
serves the variant, with `--definitions bench/definitions-crud`;
e2e/bench_test.mbt checks that each of its requests gets the CRUD operation
its `expect.crud` names.

The gRPC variant is the same set, with one more Mock, shop
(shop.bench.internal), which serves the orders over gRPC through the
service bench.shop.v1.Orders of its Descriptor set. The set is
fixtures/protobuf/bench/shop.binpb, which scripts/gen-protobuf-fixtures.sh
builds with protoc from shop.proto beside it; this script copies it to
files/shop.binpb. The Mock and its Stubs are in a file of their own,
shop.json: a GetOrder Stub for each of the 48 orders of the CRUD variant's
bucket, each matched by a condition on the order's ID and channel and
answered with a static reply; a QuoteOrder Stub whose templated reply
repeats the request's lines; and a TrackOrder Stub that answers NOT_FOUND,
which smock sends as Trailers-Only. Its request mix,
bench/requests-grpc.json, holds a call to each method, by weight, each
with a Session of its own and a body in a file of its own under
bench/requests-grpc/: the request message, encoded here by hand and
framed as gRPC frames it. bench/test_gen_definitions.py compares each
message with protoc's encoding of it, from the fixtures. bench/bench.py
sends that mix when it serves the variant, with `--definitions
bench/definitions-grpc`, in the case grpc-keep-alive of
bench/plan-autopilot.json; e2e/bench_test.mbt checks the gRPC status of
each call.

The files are checked in. Run this script again after changing it, and
commit what it writes; after changing shop.proto, run
scripts/gen-protobuf-fixtures.sh first.

usage: python3 bench/gen_definitions.py [--check]
  --check  writes nothing; exits 1 if a file of the sets, the mixes or the
           gRPC variant's bodies differs from what it would write
"""

import json
import re
import sys
import uuid
from itertools import product
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent

# Each set's directory, by its name under bench/.
SETS = ("definitions", "definitions-scenarios", "definitions-crud", "definitions-grpc")

# The request mixes of the CRUD and the gRPC variants, by their names
# under bench/.
CRUD_MIX = "requests-crud.json"
GRPC_MIX = "requests-grpc.json"

# The directory of the bodies of the gRPC variant's calls, by its name
# under bench/.
GRPC_BODIES = "requests-grpc"

# The Descriptor set of the gRPC Mock, as scripts/gen-protobuf-fixtures.sh
# builds it, and where the gRPC variant holds it, in its body-file
# subdirectory.
GRPC_SET = ROOT / "fixtures" / "protobuf" / "bench" / "shop.binpb"
GRPC_SET_NAME = "shop.binpb"

# The gRPC Mock's methods, by the path of their calls.
GRPC_SERVICE = "/bench.shop.v1.Orders/"

# The customer whose calls the gRPC variant's mix makes, the user of the
# plain mix's user-profile.
CUSTOMER = 10042

# When the first of the gRPC Mock's orders was placed, 2025-09-25T00:00:00Z,
# in milliseconds since the epoch; one more was placed each day.
FIRST_PLACED_AT_MS = 1_758_758_400_000

# The basket of the gRPC variant's mix: two items of the catalog, each with
# a quantity, which its order and its quote hold.
BASKET = [(317, 2), (42, 1)]

JSON_HEADERS = {"Content-Type": "application/json", "Cache-Control": "no-store"}
UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
CATEGORIES = ["lighting", "furniture", "kitchen", "garden", "office", "storage"]
CHANNELS = ["web", "app", "partner", "pos", "call-center", "kiosk"]
TIERS = ["bronze", "silver", "gold", "platinum", "staff", "trial", "b2b", "vip"]
CURRENCIES = ["USD", "GBP", "JPY", "EUR", "CHF", "SEK"]
ORDER_STATUSES = ["created", "paid", "shipped", "delivered", "cancelled"]

# The numbers of the values of the enum bench.shop.v1.Channel, by the
# channel each names, in the order of CHANNELS; CHANNEL_UNSPECIFIED is 0.
CHANNEL_NUMBERS = {channel: number for number, channel in enumerate(CHANNELS, start=1)}

# The order that the requests of the mix read and update.
ORDER = "7f9c2ba4-e88f-4c1a-9c5b-2d3a1e8f6b10"

# That order, as get-order answers it.
MIX_ORDER = {"id": ORDER, "status": "paid", "total": {"amount": 10597, "currency": "EUR"}}

# Each CRUD Stub's headers besides those smock sets, as the Stubs it takes
# the place of answer.
CRUD_HEADERS = {"Cache-Control": "no-store"}


def body(value):
    """A response body: `value` as compact JSON."""
    return json.dumps(value, separators=(",", ":"))


def mocks():
    return {
        "mocks": [
            {"name": "catalog", "hosts": ["catalog.bench.internal"]},
            {"name": "users", "hosts": ["users.bench.internal"]},
            {"name": "orders", "hosts": ["orders.bench.internal"]},
            {"name": "payments", "hosts": ["payments.bench.internal"], "default": True},
        ]
    }


def item_price(i):
    """The price of the catalog's item `i`, from 1, in euro cents."""
    return 499 + (i * 37) % 9500


def catalog_items():
    """The catalog's 600 items, in order."""
    return [
        {
            "sku": f"SKU-{i:05d}",
            "name": f"Item {i}",
            "category": CATEGORIES[i % len(CATEGORIES)],
            "price": {"amount": item_price(i), "currency": "EUR"},
            "stock": (i * 13) % 50,
        }
        for i in range(1, 601)
    ]


def catalog():
    stubs = []
    for i, item in enumerate(catalog_items(), start=1):
        stubs.append(
            {
                "id": f"catalog-item-{i:05d}",
                "mock": "catalog",
                "request": {"method": "GET", "path": f"/catalog/items/{item['sku']}"},
                "response": {"status": 200, "headers": JSON_HEADERS, "body": body(item)},
            }
        )
    stubs += [
        {
            "id": "catalog-search",
            "mock": "catalog",
            "request": {
                "method": "GET",
                "path": "/catalog/search",
                "query": {"q": {"pattern": "[a-z ]+"}, "page": {"pattern": "[0-9]+"}},
            },
            "response": {
                "status": 200,
                "headers": JSON_HEADERS,
                "bodyFile": "search-results.json",
            },
        },
        {
            "id": "catalog-item-reviews",
            "mock": "catalog",
            "request": {"method": "GET", "path": {"pattern": "/catalog/items/SKU-[0-9]{5}/reviews"}},
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"reviews": []})},
        },
        {
            "id": "catalog-category",
            "mock": "catalog",
            "request": {"method": "GET", "path": {"pattern": "/catalog/categories/[a-z-]+"}},
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"items": []})},
        },
    ]
    return {"stubs": stubs}


def search_results():
    items = [
        {
            "sku": f"SKU-{i:05d}",
            "name": f"Item {i}",
            "category": CATEGORIES[i % len(CATEGORIES)],
            "price": {"amount": item_price(i), "currency": "EUR"},
        }
        for i in range(311, 323)
    ]
    return json.dumps({"page": 2, "pageSize": 12, "total": 87, "items": items}, indent=2) + "\n"


def users():
    stubs = []
    for i in range(1, 301):
        user = 10000 + i
        stubs.append(
            {
                "id": f"user-{user}",
                "mock": "users",
                "request": {
                    "method": "GET",
                    "path": f"/users/{user}",
                    "headers": {"Authorization": {"pattern": "Bearer [A-Za-z0-9._-]+"}},
                },
                "response": {
                    "status": 200,
                    "headers": JSON_HEADERS,
                    "body": body(
                        {
                            "id": user,
                            "name": f"User {user}",
                            "email": f"user{user}@example.com",
                            "locale": "en-GB",
                            "tier": TIERS[i % len(TIERS)],
                            "createdAt": "2025-03-14T09:26:53Z",
                        }
                    ),
                },
            }
        )
    stubs += [
        {
            "id": "user-preferences",
            "mock": "users",
            "request": {"method": "GET", "path": {"pattern": "/users/[0-9]+/preferences"}},
            "response": {
                "status": 200,
                "headers": JSON_HEADERS,
                "body": body({"newsletter": False, "currency": "EUR", "language": "en"}),
            },
        },
        {
            "id": "user-addresses",
            "mock": "users",
            "request": {"method": "GET", "path": {"pattern": "/users/[0-9]+/addresses"}},
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"addresses": []})},
        },
    ]
    return {"stubs": stubs}


def orders():
    stubs = []
    for channel in CHANNELS:
        for tier in TIERS:
            stubs.append(
                {
                    "id": f"create-order-{channel}-{tier}",
                    "mock": "orders",
                    "request": {
                        "method": "POST",
                        "path": "/orders",
                        "query": {"dryRun": "false"},
                        "headers": {"Content-Type": "application/json"},
                        "body": {"json": {"channel": channel, "customer": {"tier": tier}}},
                    },
                    "response": {
                        "status": 201,
                        "headers": {
                            **JSON_HEADERS,
                            "Location": f"/orders/{ORDER}",
                        },
                        "body": body(
                            {
                                "id": ORDER,
                                "status": "created",
                                "channel": channel,
                                "tier": tier,
                                "total": {"amount": 10597, "currency": "EUR"},
                            }
                        ),
                    },
                }
            )
    stubs += [
        {
            "id": "get-order",
            "mock": "orders",
            "request": {"method": "GET", "path": {"pattern": f"/orders/{UUID}"}},
            "response": {
                "status": 200,
                "headers": JSON_HEADERS,
                "body": body(MIX_ORDER),
            },
        },
        {
            "id": "update-order-status",
            "mock": "orders",
            "request": {
                "method": "PUT",
                "path": {"pattern": f"/orders/{UUID}/status"},
                "body": {"pattern": '(?s).*"status":"(paid|shipped|delivered|cancelled)".*'},
            },
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"updated": True})},
        },
    ]
    return {"stubs": stubs}


def orders_data():
    """An order for each way to create one: the mix's order (partner, gold),
    with get-order's id, status and total, and one made up for each other
    way. Each item has its channel and tier after its status."""
    data = []
    for i, (channel, tier) in enumerate(product(CHANNELS, TIERS)):
        if (channel, tier) == ("partner", "gold"):
            order = MIX_ORDER
        else:
            order_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://orders.bench.internal/orders/{channel}-{tier}"))
            order = {"id": order_id, "status": ORDER_STATUSES[i % len(ORDER_STATUSES)],
                     "total": {"amount": 1999 + (i * 731) % 15000, "currency": "EUR"}}
        data.append({"id": order["id"], "status": order["status"], "channel": channel, "tier": tier,
                     "total": order["total"]})
    return data


def payments():
    stubs = [
        {
            "id": f"create-payment-{currency.lower()}",
            "mock": "payments",
            "request": {
                "method": "POST",
                "path": "/payments",
                "headers": {"Idempotency-Key": {"pattern": UUID}},
                "body": {"json": {"currency": currency, "method": {"type": "card"}}},
            },
            "response": {
                "status": 201,
                "headers": JSON_HEADERS,
                "body": body({"id": "PAY-000042", "status": "authorised", "currency": currency}),
            },
        }
        for currency in CURRENCIES
    ]
    for i in range(1, 201):
        stubs.append(
            {
                "id": f"payment-{i:06d}",
                "mock": "payments",
                "request": {"method": "GET", "path": f"/payments/PAY-{i:06d}"},
                "response": {
                    "status": 200,
                    "headers": JSON_HEADERS,
                    "body": body(
                        {
                            "id": f"PAY-{i:06d}",
                            "status": "captured",
                            "amount": {"value": 1000 + i * 7, "currency": "EUR"},
                        }
                    ),
                },
            }
        )
    return {"stubs": stubs}


def channel_name(channel):
    """The name of the value of the enum bench.shop.v1.Channel for one of
    CHANNELS, such as CHANNEL_CALL_CENTER for call-center."""
    return "CHANNEL_" + channel.upper().replace("-", "_")


def grpc_line(number, quantity):
    """A bench.shop.v1.Line as ProtoJSON: `quantity` of the catalog's item
    `number`, at its price."""
    return {"sku": f"SKU-{number:05d}", "quantity": quantity,
            "price": {"amountMinor": item_price(number), "currency": "EUR"}}


def grpc_orders():
    """The gRPC Mock's orders as GetOrder answers them, bench.shop.v1.Order
    as ProtoJSON: one for each order of the CRUD variant's bucket
    (orders_data), in its order, with its ID, status and channel, two lines
    of the catalog's items, their total, and the time it was placed, one a
    day. The mix's order is the CRUD variant's, paid, for the mix's
    customer and the mix's basket."""
    orders = []
    for i, order in enumerate(orders_data()):
        mine = order["id"] == ORDER
        basket = BASKET if mine else [((i * 37) % 600 + 1, 1 + i % 3), ((i * 53 + 11) % 600 + 1, 1)]
        lines = [grpc_line(number, quantity) for number, quantity in basket]
        total = sum(line["quantity"] * line["price"]["amountMinor"] for line in lines)
        orders.append({"id": order["id"], "customerId": CUSTOMER if mine else 10001 + (i * 37) % 300,
                       "status": f"STATUS_{order['status'].upper()}", "channel": channel_name(order["channel"]),
                       "lines": lines, "total": {"amountMinor": total, "currency": "EUR"},
                       "placedAtUnixMs": FIRST_PLACED_AT_MS + i * 86_400_000})
    return orders


def shop():
    """The gRPC Mock, shop, with its Descriptor set, and its Stubs: a
    GetOrder Stub for each order, matched by its ID and its channel and
    answered with the order, a static reply; a QuoteOrder Stub, whose
    templated reply repeats the request's lines; and a TrackOrder Stub that
    answers NOT_FOUND, with no reply message, which smock sends as
    Trailers-Only."""
    stubs = [
        {
            "id": f"get-order-{order['channel']}-{order['tier']}",
            "mock": "shop",
            "request": {"path": GRPC_SERVICE + "GetOrder",
                        "body": {"json": {"orderId": reply["id"], "channel": reply["channel"]}}},
            "response": {"json": reply},
        }
        for order, reply in zip(orders_data(), grpc_orders(), strict=True)
    ]
    stubs += [
        {
            "id": "quote-order",
            "mock": "shop",
            "request": {"path": GRPC_SERVICE + "QuoteOrder"},
            "response": {
                "template": True,
                "json": {
                    "customerId": "${body.customerId}",
                    "lines": {"$each": "body.lines", "as": "line",
                              "do": {"sku": "${line.sku}", "quantity": "${line.quantity}", "price": "${line.price}"}},
                    "total": {"amountMinor": sum(quantity * item_price(number) for number, quantity in BASKET),
                              "currency": "EUR"},
                    "coupon": "${body.coupon}",
                },
            },
        },
        {
            "id": "track-order",
            "mock": "shop",
            "request": {"path": GRPC_SERVICE + "TrackOrder"},
            "response": {"grpc": {"status": "NOT_FOUND", "message": "no shipment for this order yet"}},
        },
    ]
    return {
        "mocks": [{"name": "shop", "hosts": ["shop.bench.internal"], "grpc": {"descriptorSet": GRPC_SET_NAME}}],
        "stubs": stubs,
    }


def varint(value):
    """A non-negative integer as a protobuf varint: seven bits an octet,
    the lowest first, with the high bit set on every octet but the last."""
    out = bytearray()
    while value > 0x7F:
        out.append(value & 0x7F | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def protobuf_message(*fields):
    """A protobuf message of `fields`, (number, value) pairs, encoded by
    hand as protoc encodes them, in the order given, which is field-number
    order: a non-negative int, a number or an enum's, as a varint (wire
    type 0); a str, in UTF-8, or the bytes of a nested message, with their
    length (wire type 2). An int of 0 or an empty str is left out, as
    proto3 leaves out a field without presence at its default."""
    out = bytearray()
    for number, value in fields:
        if value == 0 or value == "":
            continue
        if isinstance(value, int):
            out += varint(number << 3) + varint(value)
        else:
            octets = value.encode() if isinstance(value, str) else value
            out += varint(number << 3 | 2) + varint(len(octets)) + octets
    return bytes(out)


def framed(message):
    """A message framed as gRPC frames one that is not compressed: the
    flag 0, then its length in four octets, big-endian, then the message."""
    return b"\x00" + len(message).to_bytes(4, "big") + message


def line_message(number, quantity):
    """A bench.shop.v1.Line, encoded: `quantity` of the catalog's item
    `number`, at its price, a bench.shop.v1.Money."""
    price = protobuf_message((1, item_price(number)), (2, "EUR"))
    return protobuf_message((1, f"SKU-{number:05d}"), (2, quantity), (3, price))


def grpc_bodies():
    """The body of each call of the gRPC variant's mix, by the call's name:
    its request message, encoded by hand and framed. get-order asks for the
    mix's order (bench.shop.v1.GetOrderRequest), quote-order for the price
    of the mix's basket with a coupon (QuoteRequest), and track-order for
    where the mix's order is (TrackOrderRequest), each for the mix's
    customer."""
    return {
        "get-order": framed(protobuf_message((1, ORDER), (2, CUSTOMER), (3, CHANNEL_NUMBERS["partner"]))),
        "quote-order": framed(protobuf_message((1, CUSTOMER), (2, CHANNEL_NUMBERS["app"]),
                                               *((3, line_message(number, quantity)) for number, quantity in BASKET),
                                               (4, "WELCOME10"))),
        "track-order": framed(protobuf_message((1, ORDER), (2, CUSTOMER))),
    }


def grpc_mix():
    """The gRPC variant's request mix: a call to each method of the gRPC
    Mock, by weight, each with its body in a file of its own (grpc_bodies)
    and a Session of its own, with the headers a gRPC client sends over
    HTTP/2 (lower-case names, the content type and te: trailers), a bearer
    token and a trace context. Each names the gRPC status the Journal
    records for it (`expect.grpcStatus`), which oha does not see."""
    calls = (
        ("get-order", 60, "GetOrder", "get-order-partner-gold", "OK", "5fb6b8c4d2a1e370"),
        ("quote-order", 25, "QuoteOrder", "quote-order", "OK", "8a3c60f7d188e3b2"),
        ("track-order", 15, "TrackOrder", "track-order", "NOT_FOUND", "c2f1e7a95b04d6e8"),
    )
    requests = [
        {
            "name": name,
            "weight": weight,
            "method": "POST",
            "host": "shop.bench.internal",
            "target": GRPC_SERVICE + method,
            "headers": [
                ["content-type", "application/grpc"],
                ["te", "trailers"],
                ["user-agent", "grpc-java-netty/1.85.1"],
                ["grpc-accept-encoding", "gzip"],
                ["authorization", "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzdG9yZWZyb250IiwiYXVkIjoib3J"
                                  "kZXJzIiwiZXhwIjoxOTI0OTkyMDAwfQ.bm90LWEtcmVhbC1zaWduYXR1cmUtYmVuY2htYXJrLW9ubHk"],
                ["traceparent", f"00-4bf92f3577b34da6a3ce929d0e0e4736-{span}-01"],
                ["baggage", f"tenant=acme-eu,smock-session=bench-grpc-{name},deployment=perf"],
            ],
            "body": None,
            "bodyFile": f"{GRPC_BODIES}/{name}.grpc",
            "expect": {"session": f"bench-grpc-{name}", "status": 200, "grpcStatus": status, "mock": "shop",
                       "stub": stub, "viaDefault": False},
        }
        for name, weight, method, stub, status, span in calls
    ]
    about = ("The request mix of the gRPC variant of the release benchmark's definitions (bench/definitions-grpc/), "
             "which bench/bench.py sends when it serves that variant, in the case grpc-keep-alive. "
             "bench/gen_definitions.py writes it: a gRPC call to each method of the Mock shop, by weight, each with "
             "a Session of its own, the headers a gRPC client sends over HTTP/2, and its framed request message in "
             "a file under bench/ (`bodyFile`), which oha sends with -D. get-order is matched by a condition on the "
             "message and gets a static reply, quote-order a templated reply, and track-order NOT_FOUND, sent as "
             "Trailers-Only. Every call gets the HTTP status 200, which is all that oha sees; `expect.grpcStatus` "
             "is the gRPC status that the Journal records, which e2e/bench_test.mbt checks.")
    return mix_file(about, requests)


def definition_file(content):
    """A Definition file with one Mock, Stub or Data bucket per line, so
    that a change shows as a change to that line."""
    lists = []
    for key, items in content.items():
        lines = [json.dumps(item, separators=(", ", ": ")) for item in items]
        lists.append('  "%s": [\n    %s\n  ]' % (key, ",\n    ".join(lines)))
    return "{\n%s\n}\n" % ",\n".join(lists)


def bucket_file(items):
    """A Data bucket's file: a JSON array with one item per line."""
    lines = [json.dumps(item, separators=(", ", ": ")) for item in items]
    return "[\n  %s\n]\n" % ",\n  ".join(lines)


def with_scenarios(content, mix):
    """The Scenario variant of a Definition file's content: each Stub that a
    request of `mix` names gets a clause of the Scenario named for the
    request, which requires Started and moves to Seen, and is followed by
    its twin, <id>-seen, which requires Seen and moves back to Started."""
    (key, items), = content.items()
    if key != "stubs":
        return content
    named = {request["expect"]["stub"]: request["name"] for request in mix}
    stubs = []
    for stub in items:
        name = named.get(stub["id"])
        if name is None:
            stubs.append(stub)
            continue
        stubs.append({**stub, "scenario": {"name": name, "requires": "Started", "moveTo": "Seen"}})
        stubs.append({**stub, "id": f"{stub['id']}-seen",
                      "scenario": {"name": name, "requires": "Seen", "moveTo": "Started"}})
    return {key: stubs}


def is_item_stub(stub):
    """Whether `stub` is one of the catalog's 600 item Stubs, whose IDs are
    catalog-item-00001 to catalog-item-00600."""
    return re.fullmatch(r"catalog-item-\d{5}", stub["id"]) is not None


def with_crud(name, content):
    """The CRUD variant of the Definition file `name`'s content: in the
    catalog, the bucket `items` and the CRUD Stub `catalog-items` in place
    of the 600 item Stubs; in the orders, the bucket `orders` and the CRUD
    Stub `orders` in place of get-order, after the Stubs that create an
    order, so that a POST to /orders still creates nothing."""
    if name == "catalog.json":
        stubs = [stub for stub in content["stubs"] if not is_item_stub(stub)]
        return {"data": [{"mock": "catalog", "name": "items", "key": "sku", "jsonFile": "items.json"}],
                "stubs": [{"id": "catalog-items", "mock": "catalog",
                           "crud": {"bucket": "items", "path": "/catalog/items", "headers": CRUD_HEADERS}},
                          *stubs]}
    if name == "orders.json":
        crud = {"id": "orders", "mock": "orders",
                "crud": {"bucket": "orders", "path": "/orders", "headers": CRUD_HEADERS}}
        return {"data": [{"mock": "orders", "name": "orders", "key": "id", "jsonFile": "orders.json"}],
                "stubs": [crud if stub["id"] == "get-order" else stub for stub in content["stubs"]]}
    return content


def crud_mix(mix):
    """The CRUD variant's request mix: `mix`, but the catalog search becomes
    catalog-list, a list query, and the status update becomes update-order,
    a PATCH of the order, each with the headers and body of the request it
    replaces and a Session of its own; the requests that a CRUD Stub
    answers name it, and each request names the CRUD operation it makes
    (`expect.crud`), or none."""
    def renamed(request, name, session):
        """`request` named `name`, with the Session `session` in its
        baggage."""
        old = request["expect"]["session"]
        headers = [[header, value.replace(f"smock-session={old},", f"smock-session={session},")]
                   for header, value in request["headers"]]
        return {**request, "name": name, "headers": headers}

    requests = []
    for request in mix:
        crud = None
        if request["name"] == "catalog-search":
            request = {**renamed(request, "catalog-list", "bench-catalog-list"),
                       "target": "/catalog/items?category=lighting&$sort=-stock&$limit=10"}
            crud = {"session": "bench-catalog-list", "stub": "catalog-items", "crud": {"op": "list", "key": None}}
        elif request["name"] == "catalog-item":
            crud = {"stub": "catalog-items", "crud": {"op": "read", "key": "SKU-00317"}}
        elif request["name"] == "get-order":
            crud = {"stub": "orders", "crud": {"op": "read", "key": ORDER}}
        elif request["name"] == "update-order-status":
            request = {**renamed(request, "update-order", "bench-update-order"), "method": "PATCH",
                       "target": f"/orders/{ORDER}"}
            crud = {"session": "bench-update-order", "stub": "orders", "crud": {"op": "update", "key": ORDER}}
        requests.append({**request, "expect": {**request["expect"], **(crud or {"crud": None})}})
    about = ("The request mix of the CRUD variant of the release benchmark's definitions (bench/definitions-crud/), "
             "which bench/bench.py sends when it serves that variant. bench/gen_definitions.py writes it from "
             "bench/requests.json: the same requests, but catalog-search becomes catalog-list, a list query, and "
             "update-order-status becomes update-order, a PATCH of the order, each with a Session of its own. "
             "catalog-item and get-order read an item through a CRUD Stub, and no request creates one, so a "
             "Session's copy of a bucket never grows. `expect.crud` is the CRUD operation and key that the "
             "Journal records, or null; e2e/bench_test.mbt checks it.")
    return mix_file(about, requests)


def mix_file(about, requests):
    """A request mix as bench/requests.json lays it out: a request a block,
    a header a line, and `expect` on one line."""
    def value(item):
        return json.dumps(item, ensure_ascii=False)

    def request_text(request):
        lines = []
        for key, item in request.items():
            if key == "headers":
                headers = ",\n".join(f"        [{value(name)}, {value(text)}]" for name, text in item)
                lines.append(f'      "headers": [\n{headers}\n      ]')
            elif key == "expect":
                members = ", ".join(f"{value(name)}: {value(member)}" for name, member in item.items())
                lines.append(f'      "expect": {{ {members} }}')
            else:
                lines.append(f"      {value(key)}: {value(item)}")
        return "    {\n" + ",\n".join(lines) + "\n    }"

    return ("{\n" + f'  "about": {value(about)},\n' + '  "requests": [\n'
            + ",\n".join(request_text(request) for request in requests) + "\n  ]\n}\n")


def files():
    """Every file of the four sets, the request mixes of the CRUD and the
    gRPC variants, and the bodies of the gRPC variant's calls, by its path
    under bench/: its content as bytes."""
    contents = {
        "00-mocks.json": mocks(),
        "catalog.json": catalog(),
        "users.json": users(),
        "orders.json": orders(),
        "payments.json": payments(),
    }
    mix = json.loads((BENCH / "requests.json").read_text())["requests"]
    written = {}
    for directory, transform in (("definitions", lambda name, content: content),
                                 ("definitions-scenarios", lambda name, content: with_scenarios(content, mix)),
                                 ("definitions-crud", with_crud),
                                 ("definitions-grpc", lambda name, content: content)):
        for name, content in contents.items():
            written[f"{directory}/{name}"] = definition_file(transform(name, content))
        written[f"{directory}/files/search-results.json"] = search_results()
    written["definitions-crud/files/items.json"] = bucket_file(catalog_items())
    written["definitions-crud/files/orders.json"] = bucket_file(orders_data())
    written[CRUD_MIX] = crud_mix(mix)
    written["definitions-grpc/shop.json"] = definition_file(shop())
    written = {name: text.encode() for name, text in written.items()}
    written[f"definitions-grpc/files/{GRPC_SET_NAME}"] = GRPC_SET.read_bytes()
    written[GRPC_MIX] = grpc_mix().encode()
    for name, body in grpc_bodies().items():
        written[f"{GRPC_BODIES}/{name}.grpc"] = body
    return written


def main(argv):
    if argv not in ([], ["--check"]):
        print(__doc__.split("usage: ")[1], file=sys.stderr)
        return 2
    wanted = files()
    present = {
        str(path.relative_to(BENCH)): path.read_bytes()
        for name in (*SETS, GRPC_BODIES)
        for path in sorted((BENCH / name).rglob("*"))
        if path.is_file()
    }
    for name in (CRUD_MIX, GRPC_MIX):
        if (BENCH / name).is_file():
            present[name] = (BENCH / name).read_bytes()
    sets = (", ".join(f"bench/{name}/" for name in SETS) + f", bench/{CRUD_MIX}, bench/{GRPC_MIX} and "
            f"bench/{GRPC_BODIES}/")
    if argv == ["--check"]:
        stale = sorted(name for name in set(wanted) | set(present) if wanted.get(name) != present.get(name))
        for name in stale:
            print(f"gen_definitions: bench/{name} is not what the script writes", file=sys.stderr)
        if stale:
            print("gen_definitions: run python3 bench/gen_definitions.py and commit the result", file=sys.stderr)
            return 1
        print(f"gen_definitions: {sets} are up to date ({len(wanted)} files)")
        return 0
    for name in set(present) - set(wanted):
        (BENCH / name).unlink()
    for name, content in wanted.items():
        path = BENCH / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    print(f"gen_definitions: wrote {len(wanted)} files to {sets}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
