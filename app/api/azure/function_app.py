"""Azure Functions entry point (Python v2 programming model).

Standby copy of the AWS order API. Same routes, same pricing module, but
persists to Cosmos DB (free tier) using the Function App's managed identity:
there are no database keys anywhere (local auth is disabled on the account).
"""
import json
import logging
import os

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

from pricing import CONTACT_RETENTION_DAYS, OrderError, load_menu, price_order, whatsapp_text

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
MENU = load_menu()

_client = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=DefaultAzureCredential())
_db = _client.get_database_client(os.environ.get("COSMOS_DATABASE", "frostyirie"))
_orders = _db.get_container_client("orders")
_contacts = _db.get_container_client("contacts")


def _resp(status, body):
    return func.HttpResponse(json.dumps(body, ensure_ascii=False), status_code=status,
                             mimetype="application/json", headers={"cache-control": "no-store"})


@app.route(route="health", methods=["GET"])
def health(_req: func.HttpRequest) -> func.HttpResponse:
    return _resp(200, {"ok": True, "cloud": "azure", "menuVersion": MENU["version"]})


@app.route(route="orders", methods=["POST"])
def create_order(req: func.HttpRequest) -> func.HttpResponse:
    body = req.get_body()
    if len(body) > 16_384:
        return _resp(413, {"error": "payload too large"})
    try:
        priced = price_order(json.loads(body or b"null"), MENU, source_cloud="azure")
    except (OrderError, json.JSONDecodeError) as exc:
        return _resp(400, {"error": str(exc)})

    order = {**priced.order, "id": priced.order["orderId"]}
    contact = {**priced.contact, "id": priced.contact["orderId"],
               "ttl": CONTACT_RETENTION_DAYS * 86400}
    _contacts.create_item(contact)
    _orders.create_item(order)
    logging.info(json.dumps({"event": "order_created", "orderId": order["orderId"],
                             "total": order["total"], "type": order["orderType"]}))
    return _resp(201, {"orderId": order["orderId"], "total": order["total"], "order": priced.order,
                       "whatsappText": whatsapp_text(priced.order, priced.contact)})
