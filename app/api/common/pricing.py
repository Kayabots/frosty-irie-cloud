"""Cloud-agnostic order validation and pricing for Frosty Irie.

Both the AWS Lambda and the Azure Function import this module, so an order
priced in either cloud produces the same totals. Prices always come from
menu.json on the server; prices sent by the browser are ignored.
"""
from __future__ import annotations

import hashlib
import json
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

MENU_PATH = Path(__file__).with_name("menu.json")

MAX_LINES = 25
MAX_QTY_PER_LINE = 20
PHONE_RE = re.compile(r"^\+?[0-9 ()-]{8,20}$")
ORDER_TYPES = {"delivery", "pickup", "beach"}
CONTACT_RETENTION_DAYS = 30


class OrderError(ValueError):
    """Raised for any client-side problem with the order payload (HTTP 400)."""


@dataclass(frozen=True)
class PricedOrder:
    order: dict[str, Any]      # financial record, no direct personal data
    contact: dict[str, Any]    # personal data, short retention


def load_menu(path: Path = MENU_PATH) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def _clean(value: Any, field: str, max_len: int, required: bool = True) -> str:
    text = str(value or "").strip()
    text = re.sub(r"[\x00-\x1f\x7f<>]", "", text)
    if required and not text:
        raise OrderError(f"{field} is required")
    if len(text) > max_len:
        raise OrderError(f"{field} is too long (max {max_len})")
    return text


def _in_window(now_local: datetime, start: str, end: str) -> bool:
    hhmm = now_local.strftime("%H:%M")
    return start <= hhmm < end


def new_order_id(now: datetime) -> str:
    return f"FI-{now:%y%m%d}-{secrets.token_hex(3).upper()}"


def price_order(payload: dict[str, Any], menu: dict[str, Any], now: datetime | None = None,
                source_cloud: str = "aws") -> PricedOrder:
    if not isinstance(payload, dict):
        raise OrderError("body must be a JSON object")
    if payload.get("website"):  # honeypot field, humans never fill it
        raise OrderError("rejected")
    if payload.get("consent") is not True:
        raise OrderError("privacy consent is required")

    now = now or datetime.now(timezone.utc)
    tz = ZoneInfo(menu["store"]["timezone"])
    now_local = now.astimezone(tz)
    pricing = menu["pricing"]

    order_type = payload.get("orderType")
    if order_type not in ORDER_TYPES:
        raise OrderError("orderType must be delivery, pickup or beach")

    lines_in = payload.get("items")
    if not isinstance(lines_in, list) or not lines_in:
        raise OrderError("items must be a non-empty list")
    if len(lines_in) > MAX_LINES:
        raise OrderError(f"too many lines (max {MAX_LINES})")

    catalog = {item["id"]: item for item in menu["items"]}
    hh = pricing.get("happyHour")
    happy = bool(hh) and _in_window(now_local, hh["start"], hh["end"])

    lines, subtotal = [], 0
    for raw in lines_in:
        if not isinstance(raw, dict):
            raise OrderError("each item must be an object")
        item = catalog.get(raw.get("id"))
        if item is None:
            raise OrderError(f"unknown item {raw.get('id')!r}")
        size = raw.get("size") or "single"
        if size not in item["prices"]:
            raise OrderError(f"size {size!r} not available for {item['name']}")
        qty = raw.get("qty")
        if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= MAX_QTY_PER_LINE:
            raise OrderError(f"qty must be an integer 1-{MAX_QTY_PER_LINE}")
        unit = item["prices"][size]
        if happy and item["category"] == hh["category"]:
            unit = min(unit, hh["price"])
        line_total = unit * qty
        subtotal += line_total
        lines.append({"id": item["id"], "name": item["name"], "category": item["category"],
                      "size": size, "qty": qty, "unitPrice": unit, "lineTotal": line_total})

    delivery_fee = pricing["deliveryFee"] if order_type == "delivery" else 0
    service = round(subtotal * pricing["serviceRate"]) if order_type in pricing["serviceAppliesTo"] else 0
    iva = round(subtotal * pricing["ivaRate"])
    total = subtotal + service + iva + delivery_fee

    name = _clean(payload.get("name"), "name", 60)
    phone = _clean(payload.get("phone"), "phone", 20)
    if not PHONE_RE.match(phone):
        raise OrderError("phone format is invalid")
    notes = _clean(payload.get("notes"), "notes", 300, required=False)
    address = table = ""
    if order_type == "delivery":
        address = _clean(payload.get("address"), "address", 300)
    elif order_type == "beach":
        table = _clean(payload.get("table"), "table / beach spot", 60)

    order_id = new_order_id(now)
    created = now.isoformat(timespec="seconds")
    # Pseudonymous customer key: lets analytics count repeat customers
    # without storing the phone number in the long-lived record.
    customer_key = hashlib.sha256(re.sub(r"\D", "", phone).encode()).hexdigest()[:16]

    order = {
        "orderId": order_id,
        "createdAt": created,
        "orderDate": now_local.date().isoformat(),
        "orderHour": now_local.hour,
        "orderType": order_type,
        "status": "RECEIVED",
        "channel": "web",
        "items": lines,
        "happyHour": happy,
        "subtotal": subtotal,
        "serviceCharge": service,
        "iva": iva,
        "deliveryFee": delivery_fee,
        "total": total,
        "currency": menu["currency"],
        "menuVersion": menu["version"],
        "customerKey": customer_key,
        "sourceCloud": source_cloud,
        "schemaVersion": 2,
    }
    expires = now + timedelta(days=CONTACT_RETENTION_DAYS)
    contact = {
        "orderId": order_id,
        "name": name,
        "phone": phone,
        "address": address,
        "table": table,
        "notes": notes,
        "consentAt": created,
        "expiresAt": int(expires.timestamp()),  # DynamoDB TTL (epoch seconds)
    }
    return PricedOrder(order=order, contact=contact)


def whatsapp_text(order: dict[str, Any], contact: dict[str, Any]) -> str:
    """Kitchen-ready summary the browser opens in WhatsApp after the API accepts the order."""
    labels = {"delivery": "🛵 Delivery", "pickup": "🏪 Pickup", "beach": "🏖️ Beach table"}
    rows = [f"• {ln['qty']}× {ln['name']} ({ln['size']}) ₡{ln['lineTotal']:,}" for ln in order["items"]]
    where = contact["address"] or contact["table"]
    parts = [f"🍕 *Frosty Irie order {order['orderId']}*", *rows,
             f"*Total: ₡{order['total']:,}* (IVA incl.)", f"{labels[order['orderType']]}"]
    if where:
        parts.append(f"📍 {where}")
    parts.append(f"👤 {contact['name']}")
    return "\n".join(parts)
