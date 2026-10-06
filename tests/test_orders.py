"""Unit tests for pricing rules and the AWS handler (DynamoDB mocked with moto)."""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app" / "api" / "common"))

import pricing  # noqa: E402

pricing.MENU_PATH = ROOT / "app" / "menu" / "menu.json"
MENU = pricing.load_menu(pricing.MENU_PATH)
NOON = datetime(2026, 9, 28, 18, 0, tzinfo=timezone.utc)      # 12:00 in Costa Rica
HAPPY = datetime(2026, 9, 28, 22, 30, tzinfo=timezone.utc)    # 16:30 in Costa Rica


def base(**over):
    body = {"orderType": "pickup", "name": "Ana", "phone": "+506 8888-1234", "consent": True,
            "items": [{"id": "pz-cheese", "size": "large", "qty": 1}]}
    body.update(over)
    return body


def test_server_prices_ignore_client_price():
    body = base(items=[{"id": "pz-cheese", "size": "large", "qty": 2, "unitPrice": 1}])
    o = pricing.price_order(body, MENU, NOON).order
    assert o["subtotal"] == 17000
    assert o["iva"] == 2210
    assert o["total"] == 19210


def test_delivery_fee_and_beach_service_charge():
    d = pricing.price_order(base(orderType="delivery", address="Playa Cocles, casa azul"), MENU, NOON).order
    assert d["deliveryFee"] == 1500 and d["serviceCharge"] == 0
    b = pricing.price_order(base(orderType="beach", table="Umbrella 7"), MENU, NOON).order
    assert b["serviceCharge"] == 850 and b["deliveryFee"] == 0


def test_happy_hour_applies_to_cocktails_only():
    items = [{"id": "ck-volcano", "qty": 1}, {"id": "br-imperial", "qty": 1}]
    o = pricing.price_order(base(items=items), MENU, HAPPY).order
    assert o["happyHour"] is True
    assert [ln["unitPrice"] for ln in o["items"]] == [5000, 2500]
    o2 = pricing.price_order(base(items=items), MENU, NOON).order
    assert [ln["unitPrice"] for ln in o2["items"]] == [7500, 2500]


def test_personal_data_kept_out_of_financial_record():
    priced = pricing.price_order(base(), MENU, NOON)
    blob = json.dumps(priced.order)
    assert "Ana" not in blob and "8888" not in blob
    assert priced.contact["phone"] == "+506 8888-1234"
    assert priced.contact["expiresAt"] > NOON.timestamp()


@pytest.mark.parametrize("over,msg", [
    ({"consent": False}, "consent"),
    ({"orderType": "drone"}, "orderType"),
    ({"items": []}, "items"),
    ({"items": [{"id": "nope", "qty": 1}]}, "unknown item"),
    ({"items": [{"id": "pz-cheese", "size": "xxl", "qty": 1}]}, "size"),
    ({"items": [{"id": "pz-cheese", "size": "large", "qty": 99}]}, "qty"),
    ({"items": [{"id": "pz-cheese", "size": "large", "qty": True}]}, "qty"),
    ({"phone": "call me"}, "phone"),
    ({"orderType": "delivery"}, "address"),
    ({"orderType": "beach"}, "table"),
    ({"website": "spam.example"}, "rejected"),
])
def test_rejects_bad_orders(over, msg):
    with pytest.raises(pricing.OrderError, match=msg):
        pricing.price_order(base(**over), MENU, NOON)


def test_markup_is_stripped():
    c = pricing.price_order(base(name="<script>Ana</script>"), MENU, NOON).contact
    assert "<" not in c["name"]


def test_every_menu_item_has_valid_prices():
    sizes = set(MENU["sizes"])
    for item in MENU["items"]:
        assert item["prices"], item["id"]
        assert set(item["prices"]) <= sizes, item["id"]
        assert all(isinstance(p, int) and p > 0 for p in item["prices"].values()), item["id"]


# ---------- AWS handler ----------
moto = pytest.importorskip("moto")


@pytest.fixture
def aws_handler(monkeypatch, tmp_path):
    import shutil

    import boto3
    from moto import mock_aws

    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("ORDERS_TABLE", "orders")
    monkeypatch.setenv("CONTACTS_TABLE", "contacts")
    for f in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
        monkeypatch.setenv(f, "testing")
    shutil.copy(ROOT / "app" / "menu" / "menu.json", ROOT / "app" / "api" / "common" / "menu.json")
    with mock_aws():
        ddb = boto3.client("dynamodb")
        for t in ("orders", "contacts"):
            ddb.create_table(TableName=t, BillingMode="PAY_PER_REQUEST",
                             AttributeDefinitions=[{"AttributeName": "orderId", "AttributeType": "S"}],
                             KeySchema=[{"AttributeName": "orderId", "KeyType": "HASH"}])
        sys.path.insert(0, str(ROOT / "app" / "api" / "aws"))
        sys.modules.pop("handler", None)
        import handler
        yield handler, ddb
    (ROOT / "app" / "api" / "common" / "menu.json").unlink(missing_ok=True)


def test_handler_creates_order(aws_handler):
    handler, ddb = aws_handler
    r = handler.handler({"routeKey": "POST /orders", "body": json.dumps(base())}, None)
    assert r["statusCode"] == 201
    oid = json.loads(r["body"])["orderId"]
    assert ddb.get_item(TableName="orders", Key={"orderId": {"S": oid}})["Item"]["total"]["N"]
    assert ddb.get_item(TableName="contacts", Key={"orderId": {"S": oid}})["Item"]["phone"]["S"]


def test_handler_rejects_and_health(aws_handler):
    handler, _ = aws_handler
    assert handler.handler({"routeKey": "POST /orders", "body": "{bad"}, None)["statusCode"] == 400
    assert handler.handler({"routeKey": "GET /health"}, None)["statusCode"] == 200
    assert handler.handler({"routeKey": "GET /admin"}, None)["statusCode"] == 404
