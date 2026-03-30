# Deephaven + Coinbase streaming demo

Full-stack demo: **Coinbase Exchange WebSocket** → **Deephaven** ticking tables (table publisher + ring buffer + live `agg_by`) → **Flask** JSON snapshots → **React** charts.

## Requirements

- **JDK 17+** and `JAVA_HOME` set ([Deephaven pip prerequisites](https://deephaven.io/core/docs/getting-started/pip-install/))
- **Python 3.9+** (3.14 tested)
- **Node 18+**

## Backend

```bash
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python backend/app.py
```

Avoid `flask run` with the reloader in development: it spawns a child process and can initialize a second embedded Deephaven JVM. Using `python app.py` is safest.

- Flask: [http://127.0.0.1:8082](http://127.0.0.1:8082) (override with `FLASK_PORT`)
- Embedded Deephaven UI: port `10000` by default (`DEEPHAVEN_PORT`)

Optional:

- `DEEPHAVEN_HEAP=-Xmx4g`
- `COINBASE_PRODUCTS=BTC-USD,ETH-USD`

On **Apple silicon**, the app passes `-Dprocess.info.system-info.enabled=false`. If the JVM fails on **newer JDKs** with errors about deprecated GC flags, this project uses minimal JVM boot args via `backend/jvm_config.py` (skips bundled `vmoptions` that reference removed HotSpot flags).

## Frontend

```bash
cd frontend
npm install
npm run dev
```

Open [http://127.0.0.1:5175](http://127.0.0.1:5175). Vite proxies `/api` to the Flask backend (override with `VITE_PORT`).

To call a remote API instead, set `VITE_API_BASE` (e.g. `http://127.0.0.1:8082`).

## AWS (EC2 + nginx), same as nfl-quiz

CI uploads a tarball to the **same S3 bucket + EC2 instance** as nfl-quiz’s **`AwsInfra-Ec2Nginx`** stack. Production UI base path: **`/deephaven-experiments/`** (nginx → Gunicorn → Flask + embedded Deephaven).

**Setup checklist:** see **[deploy/README.md](deploy/README.md)** (GitHub OIDC secret `AWS_ROLE_TO_ASSUME`, optional vars `AWS_REGION` / `AWS_EC2_STACK_NAME`, instance RAM/Java notes, nginx coexistence with nfl-quiz).

## References

- [Coinbase Exchange WebSocket overview](https://docs.cdp.coinbase.com/exchange/websocket-feed/overview)
- [Deephaven table publisher](https://deephaven.io/core/docs/how-to-guides/table-publisher/)
