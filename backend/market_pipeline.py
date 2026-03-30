"""
Coinbase Exchange WebSocket -> Deephaven ticking tables.

Import this module only after deephaven_server.Server(...).start() has run.
Feed: https://docs.cdp.coinbase.com/exchange/websocket-feed/overview
"""

from __future__ import annotations

import asyncio
import json
import threading
from concurrent.futures import CancelledError
from dataclasses import dataclass
from typing import Any, Callable

import websockets

from deephaven import agg
from deephaven import new_table
from deephaven import ring_table
from deephaven.column import datetime_col, double_col, string_col
from deephaven.dtypes import Instant as DHInstant
from deephaven.dtypes import double, string
from deephaven.stream.table_publisher import TablePublisher, table_publisher
from deephaven.table import Table
from deephaven.time import to_j_instant

COINBASE_WSFEED_URL = "wss://ws-feed.exchange.coinbase.com"
DEFAULT_PRODUCT_IDS = ("BTC-USD", "ETH-USD", "SOL-USD")


@dataclass
class TickerMsg:
    time: str
    product_id: str
    price: str
    best_bid: str
    best_ask: str
    last_size: str
    side: str
    volume_24h: str
    high_24h: str
    low_24h: str


def _parse_ticker(payload: dict[str, Any]) -> TickerMsg | None:
    if payload.get("type") != "ticker":
        return None
    try:
        return TickerMsg(
            time=str(payload["time"]),
            product_id=str(payload["product_id"]),
            price=str(payload["price"]),
            best_bid=str(payload.get("best_bid", "0") or "0"),
            best_ask=str(payload.get("best_ask", "0") or "0"),
            last_size=str(payload.get("last_size", "0") or "0"),
            side=str(payload.get("side", "")),
            volume_24h=str(payload.get("volume_24h", "0") or "0"),
            high_24h=str(payload.get("high_24h", "0") or "0"),
            low_24h=str(payload.get("low_24h", "0") or "0"),
        )
    except (KeyError, TypeError, ValueError):
        return None


def tickers_to_table(rows: list[TickerMsg]) -> Table:
    if not rows:
        return new_table(
            [
                datetime_col("Time", []),
                string_col("ProductId", []),
                double_col("Price", []),
                double_col("BestBid", []),
                double_col("BestAsk", []),
                double_col("LastSize", []),
                string_col("Side", []),
                double_col("Volume24h", []),
                double_col("High24h", []),
                double_col("Low24h", []),
            ]
        )
    return new_table(
        [
            datetime_col("Time", [to_j_instant(r.time) for r in rows]),
            string_col("ProductId", [r.product_id for r in rows]),
            double_col("Price", [float(r.price) for r in rows]),
            double_col("BestBid", [float(r.best_bid) for r in rows]),
            double_col("BestAsk", [float(r.best_ask) for r in rows]),
            double_col("LastSize", [float(r.last_size) for r in rows]),
            string_col("Side", [r.side for r in rows]),
            double_col("Volume24h", [float(r.volume_24h) for r in rows]),
            double_col("High24h", [float(r.high_24h) for r in rows]),
            double_col("Low24h", [float(r.low_24h) for r in rows]),
        ]
    )


async def _coinbase_ticker_loop(
    product_ids: list[str],
    on_ticker: Callable[[TickerMsg], None],
) -> None:
    """Subscribe to ticker; reconnect with backoff on failure."""
    delay = 1.0
    while True:
        try:
            async with websockets.connect(
                COINBASE_WSFEED_URL,
                ping_interval=20,
                ping_timeout=20,
            ) as ws:
                delay = 1.0
                await ws.send(
                    json.dumps(
                        {
                            "type": "subscribe",
                            "product_ids": product_ids,
                            "channels": ["ticker"],
                        }
                    )
                )
                async for raw in ws:
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    t = _parse_ticker(msg)
                    if t is not None:
                        on_ticker(t)
        except asyncio.CancelledError:
            raise
        except Exception:
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60.0)


class MarketPipeline:
    """Holds Deephaven tables fed from Coinbase ticker stream."""

    def __init__(self, product_ids: list[str] | None = None):
        self.product_ids = list(product_ids or DEFAULT_PRODUCT_IDS)
        self._buffer: list[TickerMsg] = []
        self._cancel: Callable[[], None] | None = None

        def on_flush(tp: TablePublisher) -> None:
            if not self._buffer:
                return
            batch = self._buffer
            self._buffer = []
            tp.add(tickers_to_table(batch))

        col_defs = {
            "Time": DHInstant,
            "ProductId": string,
            "Price": double,
            "BestBid": double,
            "BestAsk": double,
            "LastSize": double,
            "Side": string,
            "Volume24h": double,
            "High24h": double,
            "Low24h": double,
        }
        self.ticker_blink, self._publisher = table_publisher(
            "coinbase_ticker",
            col_defs,
            on_flush_callback=on_flush,
        )
        self.ticker_ring: Table = ring_table(self.ticker_blink, 8_000, initialize=True)

        # Rolling window stats on the ring (live aggregation as rows arrive).
        self.per_product_window: Table = self.ticker_ring.agg_by(
            [
                agg.count_("TicksInWindow"),
                agg.max_(cols=["High = Price"]),
                agg.min_(cols=["Low = Price"]),
                agg.avg(cols=["AvgPrice = Price"]),
                agg.sum_(cols=["SumSize = LastSize"]),
            ],
            by="ProductId",
        )

        # Best bid / ask and exchange 24h stats from the latest tick per product.
        self.latest_by_product: Table = self.ticker_ring.sort(
            ["ProductId", "Time"]
        ).last_by("ProductId")

        self.spread_table: Table = self.latest_by_product.update(
            ["Spread = BestAsk - BestBid", "Mid = (BestAsk + BestBid) / 2"]
        )

    def start_background(self, loop: asyncio.AbstractEventLoop) -> None:
        def on_ticker(t: TickerMsg) -> None:
            self._buffer.append(t)

        fut = asyncio.run_coroutine_threadsafe(
            _coinbase_ticker_loop(self.product_ids, on_ticker), loop
        )

        def _done(f):
            try:
                exc = f.exception(timeout=0)
                err = exc or RuntimeError("coinbase stream finished")
            except CancelledError:
                err = RuntimeError("coinbase stream cancelled")
            try:
                self._publisher.publish_failure(err)
            except Exception:
                pass

        fut.add_done_callback(_done)
        self._cancel = fut.cancel

    def shutdown(self) -> None:
        if self._cancel:
            self._cancel()
            self._cancel = None
        try:
            self._publisher.publish_failure(RuntimeError("shutdown"))
        except Exception:
            pass


def start_event_loop_thread() -> tuple[asyncio.AbstractEventLoop, threading.Thread]:
    loop = asyncio.new_event_loop()

    def run():
        asyncio.set_event_loop(loop)
        loop.run_forever()

    t = threading.Thread(target=run, name="asyncio-coinbase", daemon=True)
    t.start()
    return loop, t
