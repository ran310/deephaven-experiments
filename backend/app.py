"""
Flask API + embedded Deephaven.

Local dev: from repo root, `python -m backend.app` or `cd backend && python app.py`.
Production: Gunicorn uses `backend.app:app` with cwd = repo root — backend modules use relative imports.
Requires JDK 17+ and JAVA_HOME. If the JVM rejects default Deephaven GC flags,
minimal JVM args are applied via jvm_config (see jvm_config.py).
"""

from __future__ import annotations

import os

from flask import Flask, abort, jsonify, send_from_directory
from flask_cors import CORS

_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

_pipeline = None
_loop = None


def _bootstrap_deephaven() -> None:
    global _pipeline, _loop
    if _pipeline is not None:
        return

    from deephaven_server import Server

    try:
        from .jvm_config import minimal_default_jvm_args, user_jvm_args
    except ImportError:
        from jvm_config import minimal_default_jvm_args, user_jvm_args

    port = int(os.environ.get("DEEPHAVEN_PORT", "10000"))
    heap = os.environ.get("DEEPHAVEN_HEAP", "-Xmx2g")
    Server(
        port=port,
        jvm_args=user_jvm_args(heap),
        default_jvm_args=minimal_default_jvm_args(),
    ).start()

    try:
        from .market_pipeline import MarketPipeline, start_event_loop_thread
    except ImportError:
        from market_pipeline import MarketPipeline, start_event_loop_thread

    products = os.environ.get("COINBASE_PRODUCTS", "BTC-USD,ETH-USD,SOL-USD").split(",")
    products = [p.strip() for p in products if p.strip()]

    _loop, _thr = start_event_loop_thread()
    _pipeline = MarketPipeline(products)
    _pipeline.start_background(_loop)


def create_app() -> Flask:
    _bootstrap_deephaven()

    app = Flask(__name__)
    CORS(app)

    @app.get("/api/health")
    def health():
        from deephaven_server import Server as DHServer

        return jsonify(
            {
                "status": "ok",
                "deephaven_port": DHServer.instance.port,
                "products": _pipeline.product_ids,
            }
        )

    @app.get("/api/tickers/recent")
    def recent():
        try:
            from .table_util import table_to_records
        except ImportError:
            from table_util import table_to_records

        lim = int(os.environ.get("RECENT_TICKS_LIMIT", "500"))
        return jsonify({"ticks": table_to_records(_pipeline.ticker_ring, tail=lim)})

    @app.get("/api/tickers/window_stats")
    def window_stats():
        """Rolling-window aggregation per product (Deephaven agg_by on ring table)."""
        try:
            from .table_util import table_to_records
        except ImportError:
            from table_util import table_to_records

        return jsonify({"rows": table_to_records(_pipeline.per_product_window, tail=32)})

    @app.get("/api/tickers/latest")
    def latest():
        try:
            from .table_util import table_to_records
        except ImportError:
            from table_util import table_to_records

        return jsonify(
            {"rows": table_to_records(_pipeline.latest_by_product, tail=32)}
        )

    @app.get("/api/tickers/spread")
    def spread():
        try:
            from .table_util import table_to_records
        except ImportError:
            from table_util import table_to_records

        return jsonify({"rows": table_to_records(_pipeline.spread_table, tail=32)})

    _register_spa_routes(app)
    return app


def _register_spa_routes(app: Flask) -> None:
    """Serve Vite production build when frontend/dist exists (EC2 / nginx subpath deploy)."""
    dist = os.path.join(_REPO_ROOT, "frontend", "dist")
    if not os.path.isdir(dist):
        return

    assets_dir = os.path.join(dist, "assets")

    @app.get("/assets/<path:filename>")
    def _vite_assets(filename: str):
        return send_from_directory(assets_dir, filename)

    @app.get("/favicon.svg")
    def _favicon():
        return send_from_directory(dist, "favicon.svg")

    @app.get("/")
    def _spa_index():
        return send_from_directory(dist, "index.html")

    @app.get("/<path:path>")
    def _spa_or_static(path: str):
        if path == "api" or path.startswith("api/") or path.startswith("assets/"):
            abort(404)
        candidate = os.path.join(dist, path)
        if path and os.path.isfile(candidate):
            return send_from_directory(dist, path)
        return send_from_directory(dist, "index.html")


app = create_app()

if __name__ == "__main__":
    flask_port = int(os.environ.get("FLASK_PORT", "8082"))
    app.run(host="0.0.0.0", port=flask_port, threaded=True)
