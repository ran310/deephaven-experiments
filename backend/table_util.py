"""Convert Deephaven table snapshots to JSON-serializable records."""

from __future__ import annotations

import math
from typing import Any

import pandas as pd

from deephaven.pandas import to_pandas
from deephaven.table import Table


def table_to_records(t: Table, tail: int | None = 400) -> list[dict[str, Any]]:
    view = t.tail(tail) if tail else t
    df = to_pandas(view)
    records: list[dict[str, Any]] = []
    for row in df.replace({float("nan"): None}).to_dict(orient="records"):
        rec: dict[str, Any] = {}
        for k, v in row.items():
            if v is None:
                rec[k] = None
            elif isinstance(v, pd.Timestamp):
                rec[k] = v.isoformat()
            elif isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
                rec[k] = None
            else:
                rec[k] = v
        records.append(rec)
    return records
