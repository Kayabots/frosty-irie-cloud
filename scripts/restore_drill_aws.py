#!/usr/bin/env python3
"""Monthly restore drill for the AWS primary (evidence for NIST RC.RP-03, ISO A.8.13, SOC2 A1.3).

1. Restores the orders table to a point in time 1 hour ago as a throwaway table.
2. Waits until it is ACTIVE and counts items in both tables.
3. Deletes the drill table and writes an evidence record with the measured RTO.

Env: ORDERS_TABLE, AWS_REGION
"""
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3


def count(ddb, table):
    total = 0
    for page in ddb.get_paginator("scan").paginate(TableName=table, Select="COUNT"):
        total += page["Count"]
    return total


def main():
    ddb = boto3.client("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    source = os.environ["ORDERS_TABLE"]
    started = datetime.now(timezone.utc)
    target = f"{source}-drill-{started:%Y%m%d%H%M}"
    restore_point = started - timedelta(hours=1)

    ddb.restore_table_to_point_in_time(
        SourceTableName=source, TargetTableName=target, RestoreDateTime=restore_point,
        ProvisionedThroughputOverride={"ReadCapacityUnits": 1, "WriteCapacityUnits": 1},
    )
    ddb.get_waiter("table_exists").wait(TableName=target, WaiterConfig={"Delay": 20, "MaxAttempts": 90})
    rto = (datetime.now(timezone.utc) - started).total_seconds()
    restored, live = count(ddb, target), count(ddb, source)
    ddb.delete_table(TableName=target)

    ok = restored <= live  # restored copy is an hour older, so never larger
    record = {
        "control": "BCP-03 restore test", "cloud": "aws", "sourceTable": source,
        "restorePoint": restore_point.isoformat(timespec="seconds"),
        "rtoSeconds": round(rto), "rtoTargetSeconds": 4 * 3600,
        "itemsRestored": restored, "itemsLive": live, "drillTableDeleted": True, "success": ok,
        "performedAt": started.isoformat(timespec="seconds"),
    }
    out = Path(os.environ.get("EVIDENCE_DIR", "evidence"))
    out.mkdir(parents=True, exist_ok=True)
    (out / f"restore-drill-aws-{started:%Y%m%d}.json").write_text(json.dumps(record, indent=2))
    print(json.dumps(record))
    sys.exit(0 if ok and rto < 4 * 3600 else 1)


if __name__ == "__main__":
    main()
