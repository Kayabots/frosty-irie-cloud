#!/usr/bin/env python3
"""Cross-cloud order replication for backup / restore between AWS and Azure.

  aws-to-azure  (scheduled): DynamoDB -> Cosmos DB, keeps the standby warm
  azure-to-aws  (failback) : Cosmos DB -> DynamoDB, returns orders taken during an outage

Upserts are idempotent (same orderId = same record), so reruns are safe.
Expired contact records are skipped, preserving the 30-day retention rule.

Env: ORDERS_TABLE, CONTACTS_TABLE, AWS_REGION, COSMOS_ENDPOINT, COSMOS_DATABASE
Auth: AWS and Azure default credential chains (OIDC in GitHub Actions, CLI logins locally).
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import boto3
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer

COSMOS_SYSTEM = {"_rid", "_self", "_etag", "_attachments", "_ts", "id", "ttl"}
_des, _ser = TypeDeserializer(), TypeSerializer()


def plain(v):
    if isinstance(v, Decimal):
        return int(v) if v == v.to_integral_value() else float(v)
    if isinstance(v, list):
        return [plain(x) for x in v]
    if isinstance(v, dict):
        return {k: plain(x) for k, x in v.items()}
    return v


def to_ddb(v):
    if isinstance(v, float):
        return Decimal(str(v))
    if isinstance(v, list):
        return [to_ddb(x) for x in v]
    if isinstance(v, dict):
        return {k: to_ddb(x) for k, x in v.items()}
    return v


def scan(ddb, table):
    for page in ddb.get_paginator("scan").paginate(TableName=table):
        for item in page["Items"]:
            yield plain({k: _des.deserialize(v) for k, v in item.items()})


def cosmos_containers():
    client = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=DefaultAzureCredential())
    db = client.get_database_client(os.environ.get("COSMOS_DATABASE", "frostyirie"))
    return db.get_container_client("orders"), db.get_container_client("contacts")


def aws_to_azure(ddb, stats):
    orders_c, contacts_c = cosmos_containers()
    now = int(time.time())
    for o in scan(ddb, os.environ["ORDERS_TABLE"]):
        orders_c.upsert_item({**o, "id": o["orderId"]})
        stats["orders"] += 1
    for c in scan(ddb, os.environ["CONTACTS_TABLE"]):
        remaining = int(c.get("expiresAt", 0)) - now
        if remaining <= 0:
            stats["contacts_skipped_expired"] += 1
            continue
        contacts_c.upsert_item({**c, "id": c["orderId"], "ttl": remaining})
        stats["contacts"] += 1


def azure_to_aws(ddb, stats):
    orders_c, contacts_c = cosmos_containers()
    now = int(time.time())
    for o in orders_c.read_all_items():
        item = {k: v for k, v in o.items() if k not in COSMOS_SYSTEM}
        ddb.put_item(TableName=os.environ["ORDERS_TABLE"],
                     Item={k: _ser.serialize(to_ddb(v)) for k, v in item.items()})
        stats["orders"] += 1
    for c in contacts_c.read_all_items():
        item = {k: v for k, v in c.items() if k not in COSMOS_SYSTEM}
        if int(item.get("expiresAt", 0)) <= now:
            stats["contacts_skipped_expired"] += 1
            continue
        ddb.put_item(TableName=os.environ["CONTACTS_TABLE"],
                     Item={k: _ser.serialize(to_ddb(v)) for k, v in item.items()})
        stats["contacts"] += 1


def main():
    p = argparse.ArgumentParser()
    p.add_argument("direction", choices=["aws-to-azure", "azure-to-aws"])
    p.add_argument("--evidence-dir", default="evidence")
    a = p.parse_args()

    started = datetime.now(timezone.utc)
    ddb = boto3.client("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    stats = {"orders": 0, "contacts": 0, "contacts_skipped_expired": 0}
    ok = True
    try:
        (aws_to_azure if a.direction == "aws-to-azure" else azure_to_aws)(ddb, stats)
    except Exception as exc:  # recorded as evidence, then re-raised via exit code
        ok, stats["error"] = False, f"{type(exc).__name__}: {exc}"

    record = {"control": "BCP-02 cross-cloud replication", "direction": a.direction, "success": ok,
              "startedAt": started.isoformat(timespec="seconds"),
              "durationSeconds": round((datetime.now(timezone.utc) - started).total_seconds(), 1), **stats}
    out = Path(a.evidence_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"dr-sync-{started:%Y%m%dT%H%M%SZ}.json").write_text(json.dumps(record, indent=2))
    print(json.dumps(record))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
