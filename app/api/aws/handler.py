"""AWS Lambda entry point (API Gateway HTTP API, payload v2).

Routes
  GET  /health  -> liveness probe used by the web app and Route 53 failover
  POST /orders  -> validate, price, persist atomically to DynamoDB
"""
import base64
import json
import logging
import os

import boto3
from boto3.dynamodb.types import TypeSerializer

from pricing import OrderError, load_menu, price_order, whatsapp_text

log = logging.getLogger()
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MENU = load_menu()
ORDERS_TABLE = os.environ["ORDERS_TABLE"]
CONTACTS_TABLE = os.environ["CONTACTS_TABLE"]
_ddb = boto3.client("dynamodb")
_ser = TypeSerializer()


def _item(d):
    return {k: _ser.serialize(v) for k, v in d.items()}


def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def handler(event, _context):
    route = event.get("routeKey", "")
    if route == "GET /health":
        return _resp(200, {"ok": True, "cloud": "aws", "menuVersion": MENU["version"]})
    if route != "POST /orders":
        return _resp(404, {"error": "not found"})

    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    if len(raw) > 16_384:
        return _resp(413, {"error": "payload too large"})
    try:
        priced = price_order(json.loads(raw), MENU, source_cloud="aws")
    except (OrderError, json.JSONDecodeError) as exc:
        return _resp(400, {"error": str(exc)})

    order, contact = priced.order, priced.contact
    _ddb.transact_write_items(TransactItems=[
        {"Put": {"TableName": ORDERS_TABLE, "Item": _item(order),
                 "ConditionExpression": "attribute_not_exists(orderId)"}},
        {"Put": {"TableName": CONTACTS_TABLE, "Item": _item(contact)}},
    ])
    # Log the order id and totals only; personal data never goes to logs.
    log.info(json.dumps({"event": "order_created", "orderId": order["orderId"],
                         "total": order["total"], "type": order["orderType"]}))
    return _resp(201, {"orderId": order["orderId"], "total": order["total"], "order": order,
                       "whatsappText": whatsapp_text(order, contact)})
