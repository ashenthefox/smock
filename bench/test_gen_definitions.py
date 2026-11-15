"""Tests of bench/gen_definitions.py, which writes the release benchmark's
definition sets: bench/definitions/, its Scenario variant,
bench/definitions-scenarios/, its CRUD variant, bench/definitions-crud/,
with the CRUD variant's request mix, bench/requests-crud.json, and its gRPC
variant, bench/definitions-grpc/, with the gRPC variant's request mix,
bench/requests-grpc.json, and its bodies, bench/requests-grpc/.

They read the files it wrote, which CI checks are what it writes, and run
it on a copy of bench/. They need python3 alone. e2e/bench_test.mbt checks
the sets against smock itself.

usage: python3 -m unittest discover -s bench -v
"""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent
SCRIPT = BENCH / "gen_definitions.py"

# The fixtures of the gRPC variant's set and of the messages of its mix,
# which protoc builds (scripts/gen-protobuf-fixtures.sh).
FIXTURES = BENCH.parent / "fixtures" / "protobuf" / "bench"

_spec = importlib.util.spec_from_file_location("gen_definitions", SCRIPT)
gen_definitions = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen_definitions)


def definition_files(directory):
    """The Definition files of a definitions directory, by name: {name:
    content}."""
    return {path.name: json.loads(path.read_text()) for path in sorted(Path(directory).glob("*.json"))}


def stubs_of(files):
    """The Stubs of Definition files, in their files' order, each with the
    name of its file: [(file, stub)]."""
    return [(name, stub) for name, content in files.items() for stub in content.get("stubs", [])]


class ScenarioVariant(unittest.TestCase):
    """The Scenario variant serves what the plain set does, but each Stub
    that a request of the mix names has a Scenario clause, and a twin right
    after it with the same request and response: the two take turns, so
    that every request of the mix matches one of them and moves its
    Scenario."""

    # Each Scenario Stub of the variant, in order: its file, its ID, and
    # its clause.
    SCENARIO_STUBS = [
        (file, stub_id, {"name": name, "requires": requires, "moveTo": move_to})
        for file, stub, name in (
            ("catalog.json", "catalog-item-00317", "catalog-item"),
            ("catalog.json", "catalog-search", "catalog-search"),
            ("orders.json", "create-order-partner-gold", "create-order"),
            ("orders.json", "get-order", "get-order"),
            ("orders.json", "update-order-status", "update-order-status"),
            ("payments.json", "create-payment-eur", "create-payment"),
            ("payments.json", "payment-000042", "legacy-payment"),
            ("users.json", "user-10042", "user-profile"),
            ("users.json", "user-preferences", "user-preferences"),
        )
        for stub_id, requires, move_to in ((stub, "Started", "Seen"), (f"{stub}-seen", "Seen", "Started"))
    ]

    def setUp(self):
        self.plain = definition_files(BENCH / "definitions")
        self.variant = definition_files(BENCH / "definitions-scenarios")

    def test_each_stub_the_mix_names_has_a_clause_and_a_twin_that_moves_the_scenario_back(self):
        found = [(file, stub["id"], stub["scenario"]) for file, stub in stubs_of(self.variant) if "scenario" in stub]
        self.assertEqual(found, self.SCENARIO_STUBS)
        # Each twin follows its Stub, with the same Mock, request and
        # response.
        stubs = [stub for _, stub in stubs_of(self.variant)]
        for at, stub in enumerate(stubs):
            if stub["id"].endswith("-seen"):
                before = stubs[at - 1]
                self.assertEqual(before["id"], stub["id"].removesuffix("-seen"))
                self.assertEqual({key: value for key, value in before.items() if key not in ("id", "scenario")},
                                 {key: value for key, value in stub.items() if key not in ("id", "scenario")})

    def test_without_its_scenario_stubs_clauses_and_twins_it_is_the_plain_set(self):
        self.assertEqual(sorted(self.variant), sorted(self.plain))
        without = {
            name: {key: [{member: value for member, value in item.items() if member != "scenario"}
                         for item in items if not item["id"].endswith("-seen")] if key == "stubs" else items
                   for key, items in content.items()}
            for name, content in self.variant.items()}
        self.assertEqual(without, self.plain)
        self.assertEqual((BENCH / "definitions-scenarios" / "files" / "search-results.json").read_bytes(),
                         (BENCH / "definitions" / "files" / "search-results.json").read_bytes())
        self.assertEqual(len(stubs_of(self.variant)), len(stubs_of(self.plain)) + 9)


def read_mix(name):
    """The requests of a request mix under bench/."""
    return json.loads((BENCH / name).read_text())["requests"]


class CrudVariant(unittest.TestCase):
    """The CRUD variant serves the catalog's items and the orders from Data
    buckets, each through a CRUD Stub in place of the Stubs that answered
    them one by one. Its mix is the plain one, but the catalog search
    becomes a list query and the status update a PATCH of the order: its
    requests list, read and update items, and none creates one."""

    ORDER = "7f9c2ba4-e88f-4c1a-9c5b-2d3a1e8f6b10"

    def setUp(self):
        self.plain = definition_files(BENCH / "definitions")
        self.variant = definition_files(BENCH / "definitions-crud")

    def test_the_catalog_and_the_orders_declare_a_keyed_bucket_each_from_a_file(self):
        self.assertEqual({name: content["data"] for name, content in self.variant.items() if "data" in content}, {
            "catalog.json": [{"mock": "catalog", "name": "items", "key": "sku", "jsonFile": "items.json"}],
            "orders.json": [{"mock": "orders", "name": "orders", "key": "id", "jsonFile": "orders.json"}],
        })

    def test_a_crud_stub_takes_the_place_of_the_stubs_that_answered_the_items_one_by_one(self):
        def ids(files, name):
            return [stub["id"] for stub in files[name]["stubs"]]

        catalog = ids(self.variant, "catalog.json")
        self.assertEqual(catalog, ["catalog-items", "catalog-search", "catalog-item-reviews", "catalog-category"])
        self.assertEqual(ids(self.plain, "catalog.json")[600:], catalog[1:])
        orders = ids(self.variant, "orders.json")
        plain_orders = ids(self.plain, "orders.json")
        self.assertEqual(plain_orders[48:], ["get-order", "update-order-status"])
        self.assertEqual(orders, [*plain_orders[:48], "orders", "update-order-status"])
        crud = {stub["id"]: stub for content in self.variant.values() for stub in content.get("stubs", [])
                if "crud" in stub}
        self.assertEqual(crud, {
            "catalog-items": {"id": "catalog-items", "mock": "catalog",
                              "crud": {"bucket": "items", "path": "/catalog/items",
                                       "headers": {"Cache-Control": "no-store"}}},
            "orders": {"id": "orders", "mock": "orders",
                       "crud": {"bucket": "orders", "path": "/orders", "headers": {"Cache-Control": "no-store"}}},
        })
        # The other Stubs and the Mocks are the plain set's.
        others = {name: [stub for stub in content.get("stubs", []) if "crud" not in stub]
                  for name, content in self.variant.items()}
        plain = {name: [stub for stub in content.get("stubs", [])
                        if not gen_definitions.is_item_stub(stub) and stub["id"] != "get-order"]
                 for name, content in self.plain.items()}
        self.assertEqual(others, plain)
        self.assertEqual(self.variant["00-mocks.json"], self.plain["00-mocks.json"])
        self.assertEqual((BENCH / "definitions-crud" / "files" / "search-results.json").read_bytes(),
                         (BENCH / "definitions" / "files" / "search-results.json").read_bytes())

    def test_the_items_bucket_holds_what_the_600_item_stubs_answered_in_their_order(self):
        items = json.loads((BENCH / "definitions-crud" / "files" / "items.json").read_text())
        answered = [json.loads(stub["response"]["body"]) for stub in self.plain["catalog.json"]["stubs"]
                    if gen_definitions.is_item_stub(stub)]
        self.assertEqual(len(answered), 600)
        self.assertEqual(items, answered)
        self.assertEqual(items[316], {"sku": "SKU-00317", "name": "Item 317", "category": "storage",
                                      "price": {"amount": 2728, "currency": "EUR"}, "stock": 21})
        self.assertEqual(sum(1 for item in items if item["category"] == "lighting"), 100)

    def test_the_orders_bucket_holds_an_order_for_each_way_to_create_one_the_mix_s_paid_order_among_them(self):
        orders = json.loads((BENCH / "definitions-crud" / "files" / "orders.json").read_text())
        self.assertEqual(len(orders), 48)
        self.assertEqual(len({order["id"] for order in orders}), 48)
        self.assertEqual([(order["channel"], order["tier"]) for order in orders][:3],
                         [("web", "bronze"), ("web", "silver"), ("web", "gold")])
        self.assertEqual(orders[18], {"id": self.ORDER, "status": "paid", "channel": "partner", "tier": "gold",
                                      "total": {"amount": 10597, "currency": "EUR"}})

    def test_the_crud_mix_is_the_plain_mix_but_for_a_list_query_and_a_patch_and_names_the_crud_operation(self):
        plain, crud = read_mix("requests.json"), read_mix("requests-crud.json")
        self.assertEqual([(request["name"], request["weight"]) for request in crud], [
            ("catalog-item", 30), ("catalog-list", 10), ("user-profile", 20), ("user-preferences", 5),
            ("create-order", 15), ("get-order", 5), ("update-order", 5), ("create-payment", 7),
            ("legacy-payment", 3)])
        shown = {request["name"]: (request["method"], request["target"], request["expect"]) for request in crud}
        self.assertEqual(shown["catalog-list"], (
            "GET", "/catalog/items?category=lighting&$sort=-stock&$limit=10",
            {"session": "bench-catalog-list", "status": 200, "mock": "catalog", "stub": "catalog-items",
             "viaDefault": False, "crud": {"op": "list", "key": None}}))
        self.assertEqual(shown["catalog-item"], (
            "GET", "/catalog/items/SKU-00317",
            {"session": "bench-catalog-item", "status": 200, "mock": "catalog", "stub": "catalog-items",
             "viaDefault": False, "crud": {"op": "read", "key": "SKU-00317"}}))
        self.assertEqual(shown["get-order"], (
            "GET", f"/orders/{self.ORDER}",
            {"session": "bench-get-order", "status": 200, "mock": "orders", "stub": "orders", "viaDefault": False,
             "crud": {"op": "read", "key": self.ORDER}}))
        self.assertEqual(shown["update-order"], (
            "PATCH", f"/orders/{self.ORDER}",
            {"session": "bench-update-order", "status": 200, "mock": "orders", "stub": "orders",
             "viaDefault": False, "crud": {"op": "update", "key": self.ORDER}}))
        # The list and the update take the place of the search and the
        # status update, with their headers and body, each with a Session
        # of its own; every other request is the plain mix's, with no CRUD
        # operation.
        by_name = {request["name"]: request for request in plain}
        replaced = {"catalog-list": "catalog-search", "update-order": "update-order-status"}
        for request in crud:
            before = by_name[replaced.get(request["name"], request["name"])]
            session = request["expect"]["session"]
            self.assertEqual(session, f"bench-{request['name']}")
            headers = [[name, value.replace(f"smock-session={before['expect']['session']},",
                                            f"smock-session={session},")] for name, value in before["headers"]]
            self.assertEqual(request["headers"], headers)
            self.assertEqual(request["body"], before["body"])
            self.assertEqual(request["host"], before["host"])
            if request["name"] in ("catalog-item", "catalog-list", "get-order", "update-order"):
                continue
            self.assertEqual(request, {**before, "expect": {**before["expect"], "crud": None}})
        # No request creates an item.
        self.assertNotIn("create", [(request["expect"]["crud"] or {}).get("op") for request in crud])


class GrpcVariant(unittest.TestCase):
    """The gRPC variant serves what the plain set does, and a gRPC Mock,
    shop, with its Stubs and its Descriptor set, which the fixture script
    builds. Its mix holds gRPC calls only, each with a framed protobuf body
    in a file of its own, encoded by hand: one matched by a condition on
    the request message and answered with an OK reply, one answered with a
    templated OK reply, and one answered with an error, sent as
    Trailers-Only."""

    ORDER = "7f9c2ba4-e88f-4c1a-9c5b-2d3a1e8f6b10"
    METHODS = "/bench.shop.v1.Orders/"

    def setUp(self):
        self.plain = definition_files(BENCH / "definitions")
        self.variant = definition_files(BENCH / "definitions-grpc")

    def test_it_is_the_plain_set_with_a_grpc_mock_its_stubs_and_its_set_in_a_file_of_their_own(self):
        self.assertEqual({name: content for name, content in self.variant.items() if name != "shop.json"},
                         self.plain)
        shop = self.variant["shop.json"]
        self.assertEqual(shop["mocks"], [{"name": "shop", "hosts": ["shop.bench.internal"],
                                          "grpc": {"descriptorSet": "shop.binpb"}}])
        self.assertEqual({stub["mock"] for stub in shop["stubs"]}, {"shop"})
        files = BENCH / "definitions-grpc" / "files"
        self.assertEqual(sorted(path.name for path in files.iterdir()), ["search-results.json", "shop.binpb"])
        self.assertEqual((files / "shop.binpb").read_bytes(), (FIXTURES / "shop.binpb").read_bytes())
        self.assertEqual((files / "search-results.json").read_bytes(),
                         (BENCH / "definitions" / "files" / "search-results.json").read_bytes())

    def test_an_order_is_found_by_a_condition_on_its_id_and_channel_among_one_stub_for_each_way_to_create_one(self):
        stubs = self.variant["shop.json"]["stubs"]
        orders = [stub for stub in stubs if stub["request"]["path"] == self.METHODS + "GetOrder"]
        self.assertEqual(len(orders), 48)
        self.assertEqual(len({stub["id"] for stub in orders}), 48)
        self.assertEqual(len({json.dumps(stub["request"]["body"]) for stub in orders}), 48)
        # The mix's order, paid, as the plain set's get-order answers it,
        # with two lines whose prices are those of the catalog's items.
        [mine] = [stub for stub in orders if stub["id"] == "get-order-partner-gold"]
        self.assertEqual(orders.index(mine), 18)
        self.assertEqual(mine, {
            "id": "get-order-partner-gold", "mock": "shop",
            "request": {"path": self.METHODS + "GetOrder",
                        "body": {"json": {"orderId": self.ORDER, "channel": "CHANNEL_PARTNER"}}},
            "response": {"json": {
                "id": self.ORDER, "customerId": 10042, "status": "STATUS_PAID", "channel": "CHANNEL_PARTNER",
                "lines": [{"sku": "SKU-00317", "quantity": 2, "price": {"amountMinor": 2728, "currency": "EUR"}},
                          {"sku": "SKU-00042", "quantity": 1, "price": {"amountMinor": 2053, "currency": "EUR"}}],
                "total": {"amountMinor": 7509, "currency": "EUR"}, "placedAtUnixMs": 1760313600000}},
        })
        # Every order's reply is a static message of its own.
        for stub in orders:
            reply = stub["response"]["json"]
            self.assertNotIn("template", stub["response"])
            self.assertEqual(stub["request"]["body"]["json"], {"orderId": reply["id"], "channel": reply["channel"]})
            self.assertEqual(reply["total"]["amountMinor"],
                             sum(line["quantity"] * line["price"]["amountMinor"] for line in reply["lines"]))

    def test_a_quote_is_a_templated_reply_that_repeats_the_requests_lines_and_tracking_an_order_is_not_found(self):
        stubs = {stub["id"]: stub for stub in self.variant["shop.json"]["stubs"]}
        self.assertEqual(stubs["quote-order"], {
            "id": "quote-order", "mock": "shop", "request": {"path": self.METHODS + "QuoteOrder"},
            "response": {"template": True, "json": {
                "customerId": "${body.customerId}",
                "lines": {"$each": "body.lines", "as": "line",
                          "do": {"sku": "${line.sku}", "quantity": "${line.quantity}", "price": "${line.price}"}},
                "total": {"amountMinor": 7509, "currency": "EUR"},
                "coupon": "${body.coupon}"}},
        })
        self.assertEqual(stubs["track-order"], {
            "id": "track-order", "mock": "shop", "request": {"path": self.METHODS + "TrackOrder"},
            "response": {"grpc": {"status": "NOT_FOUND", "message": "no shipment for this order yet"}},
        })
        self.assertEqual(list(stubs)[-2:], ["quote-order", "track-order"])

    def test_its_mix_holds_a_grpc_call_of_each_kind_by_weight_each_with_a_session_of_its_own(self):
        mix = read_mix("requests-grpc.json")
        self.assertEqual([(request["name"], request["weight"]) for request in mix],
                         [("get-order", 60), ("quote-order", 25), ("track-order", 15)])
        for request, method, stub, status in zip(mix, ("GetOrder", "QuoteOrder", "TrackOrder"),
                                                  ("get-order-partner-gold", "quote-order", "track-order"),
                                                  ("OK", "OK", "NOT_FOUND"), strict=True):
            name = request["name"]
            self.assertEqual((request["method"], request["host"], request["target"]),
                             ("POST", "shop.bench.internal", self.METHODS + method), name)
            # As a gRPC client sends a call over HTTP/2: lower-case names,
            # the content type and te: trailers first.
            headers = dict(request["headers"])
            self.assertEqual(request["headers"][:2], [["content-type", "application/grpc"], ["te", "trailers"]])
            self.assertEqual([header for header, _ in request["headers"]],
                             [header.lower() for header, _ in request["headers"]])
            self.assertEqual(headers["baggage"], f"tenant=acme-eu,smock-session=bench-grpc-{name},deployment=perf")
            self.assertEqual((request["body"], request["bodyFile"]), (None, f"requests-grpc/{name}.grpc"), name)
            self.assertEqual(request["expect"], {"session": f"bench-grpc-{name}", "status": 200,
                                                 "grpcStatus": status, "mock": "shop", "stub": stub,
                                                 "viaDefault": False}, name)

    def test_each_calls_body_is_its_request_message_framed_and_encoded_by_hand_as_protoc_encodes_it(self):
        # protoc's encoding of each message's text form, which the fixture
        # script writes, framed: flag 0 (not compressed), then the length
        # in four octets, big-endian.
        for request in read_mix("requests-grpc.json"):
            body = (BENCH / request["bodyFile"]).read_bytes()
            message = (FIXTURES / f"{request['name']}.binpb").read_bytes()
            self.assertEqual(body[:5], b"\x00" + len(message).to_bytes(4, "big"), request["name"])
            self.assertEqual(body[5:], message, request["name"])
        self.assertEqual(sorted(path.name for path in (BENCH / "requests-grpc").iterdir()),
                         ["get-order.grpc", "quote-order.grpc", "track-order.grpc"])


class Check(unittest.TestCase):
    """--check writes nothing, and fails when a file of a set, a mix or the
    gRPC variant's bodies is not what the script writes, naming it."""

    # What the script says when every file is what it writes.
    SETS = ("bench/definitions/, bench/definitions-scenarios/, bench/definitions-crud/, bench/definitions-grpc/, "
            "bench/requests-crud.json, bench/requests-grpc.json and bench/requests-grpc/")

    def copy(self):
        """A copy of what the script reads and writes, in a directory of its
        own: the script, the request mixes, the four sets, the gRPC
        variant's bodies, and the gRPC Mock's set among the fixtures."""
        root = Path(tempfile.mkdtemp(prefix="smock-gen-definitions-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        bench = root / "bench"
        bench.mkdir()
        for name in ("gen_definitions.py", "requests.json", "requests-crud.json", "requests-grpc.json"):
            shutil.copy2(BENCH / name, bench / name)
        for name in ("definitions", "definitions-scenarios", "definitions-crud", "definitions-grpc", "requests-grpc"):
            shutil.copytree(BENCH / name, bench / name)
        (root / "fixtures" / "protobuf" / "bench").mkdir(parents=True)
        shutil.copy2(FIXTURES / "shop.binpb", root / "fixtures" / "protobuf" / "bench" / "shop.binpb")
        return bench

    def run_script(self, bench, *args):
        result = subprocess.run([sys.executable, str(bench / "gen_definitions.py"), *args], capture_output=True,
                                text=True)
        return result.returncode, result.stdout + result.stderr

    def test_both_sets_as_written_pass(self):
        status, output = self.run_script(BENCH, "--check")
        self.assertEqual(status, 0, output)
        self.assertEqual(output, f"gen_definitions: {self.SETS} are up to date (33 files)\n")

    def test_a_changed_or_missing_file_of_the_variant_fails_and_is_named_and_a_run_writes_it_again(self):
        bench = self.copy()
        orders = bench / "definitions-scenarios" / "orders.json"
        orders.write_text(orders.read_text().replace('"moveTo": "Seen"', '"moveTo": "Paid"'))
        (bench / "definitions-scenarios" / "files" / "search-results.json").unlink()
        status, output = self.run_script(bench, "--check")
        self.assertEqual(status, 1, output)
        self.assertEqual(output, "gen_definitions: bench/definitions-scenarios/files/search-results.json is not what "
                                 "the script writes\n"
                                 "gen_definitions: bench/definitions-scenarios/orders.json is not what the script "
                                 "writes\n"
                                 "gen_definitions: run python3 bench/gen_definitions.py and commit the result\n")
        status, output = self.run_script(bench)
        self.assertEqual((status, output), (0, f"gen_definitions: wrote 33 files to {self.SETS}\n"))
        status, output = self.run_script(bench, "--check")
        self.assertEqual(status, 0, output)

    def test_a_changed_or_missing_file_of_the_crud_variant_or_its_mix_fails_and_is_named(self):
        bench = self.copy()
        items = bench / "definitions-crud" / "files" / "items.json"
        items.write_text(items.read_text().replace('"stock": 21', '"stock": 22'))
        (bench / "requests-crud.json").unlink()
        status, output = self.run_script(bench, "--check")
        self.assertEqual(status, 1, output)
        self.assertEqual(output, "gen_definitions: bench/definitions-crud/files/items.json is not what the script "
                                 "writes\n"
                                 "gen_definitions: bench/requests-crud.json is not what the script writes\n"
                                 "gen_definitions: run python3 bench/gen_definitions.py and commit the result\n")
        status, _ = self.run_script(bench)
        self.assertEqual(status, 0)
        self.assertEqual((bench / "requests-crud.json").read_bytes(), (BENCH / "requests-crud.json").read_bytes())

    def test_a_changed_body_set_or_mix_of_the_grpc_variant_or_a_file_it_does_not_write_fails_and_is_named(self):
        # Bodies and the set are compared octet for octet. A file the script
        # does not write is named too, and a run deletes it.
        bench = self.copy()
        body = bench / "requests-grpc" / "get-order.grpc"
        body.write_bytes(body.read_bytes()[:-1] + b"\x04")
        grpc_set = bench / "definitions-grpc" / "files" / "shop.binpb"
        grpc_set.write_bytes(grpc_set.read_bytes() + b"\x00")
        (bench / "requests-grpc" / "old.grpc").write_bytes(b"\x00\x00\x00\x00\x00")
        (bench / "requests-grpc.json").unlink()
        status, output = self.run_script(bench, "--check")
        self.assertEqual(status, 1, output)
        self.assertEqual(output, "gen_definitions: bench/definitions-grpc/files/shop.binpb is not what the script "
                                 "writes\n"
                                 "gen_definitions: bench/requests-grpc.json is not what the script writes\n"
                                 "gen_definitions: bench/requests-grpc/get-order.grpc is not what the script writes\n"
                                 "gen_definitions: bench/requests-grpc/old.grpc is not what the script writes\n"
                                 "gen_definitions: run python3 bench/gen_definitions.py and commit the result\n")
        status, _ = self.run_script(bench)
        self.assertEqual(status, 0)
        self.assertFalse((bench / "requests-grpc" / "old.grpc").exists())
        for name in ("requests-grpc/get-order.grpc", "definitions-grpc/files/shop.binpb", "requests-grpc.json"):
            self.assertEqual((bench / name).read_bytes(), (BENCH / name).read_bytes(), name)
        # The set comes from the fixtures: one that changes there changes
        # what the script writes.
        fixture = bench.parent / "fixtures" / "protobuf" / "bench" / "shop.binpb"
        fixture.write_bytes(fixture.read_bytes() + b"\x00")
        status, output = self.run_script(bench, "--check")
        self.assertEqual(status, 1, output)
        self.assertIn("gen_definitions: bench/definitions-grpc/files/shop.binpb is not what the script writes\n",
                      output)


if __name__ == "__main__":
    unittest.main()
