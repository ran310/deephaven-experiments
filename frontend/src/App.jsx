import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
  BarChart,
  Bar,
  Legend,
  Cell,
} from 'recharts'
import './App.css'

// Dev: proxy '' + /api. Prod: Vite BASE_URL is /deephaven-experiments/
const API =
  import.meta.env.VITE_API_BASE ??
  import.meta.env.BASE_URL.replace(/\/$/, '')

const PRODUCT_COLORS = {
  'BTC-USD': '#f7931a',
  'ETH-USD': '#627eea',
  'SOL-USD': '#9945ff',
}

function usePoll(fn, ms, deps) {
  useEffect(() => {
    let alive = true
    const tick = async () => {
      if (!alive) return
      try {
        await fn()
      } catch {
        /* surfaced in fetch helpers */
      }
    }
    tick()
    const id = setInterval(tick, ms)
    return () => {
      alive = false
      clearInterval(id)
    }
  }, deps)
}

function formatPrice(n) {
  if (n == null || Number.isNaN(n)) return '—'
  if (n >= 1000) return n.toLocaleString('en-US', { maximumFractionDigits: 2 })
  return n.toLocaleString('en-US', { maximumFractionDigits: 4 })
}

function buildProductSparklines(ticks, products, perSeries) {
  const out = {}
  for (const p of products) {
    const series = ticks
      .filter((t) => t.ProductId === p)
      .slice(-perSeries)
      .map((t, i) => ({ i, price: t.Price }))
    out[p] = series
  }
  return out
}

export default function App() {
  const [health, setHealth] = useState(null)
  const [healthErr, setHealthErr] = useState(null)
  const [ticks, setTicks] = useState([])
  const [windowStats, setWindowStats] = useState([])
  const [spreadRows, setSpreadRows] = useState([])
  const [tickErr, setTickErr] = useState(null)

  const products = useMemo(
    () => health?.products ?? ['BTC-USD', 'ETH-USD', 'SOL-USD'],
    [health],
  )

  const fetchHealth = useCallback(async () => {
    const r = await fetch(`${API}/api/health`)
    if (!r.ok) throw new Error('health')
    const j = await r.json()
    setHealth(j)
    setHealthErr(null)
  }, [])

  const fetchTicks = useCallback(async () => {
    try {
      const r = await fetch(`${API}/api/tickers/recent`)
      if (!r.ok) throw new Error('ticks')
      const j = await r.json()
      setTicks(j.ticks ?? [])
      setTickErr(null)
    } catch {
      setTickErr('poll failed')
    }
  }, [])

  const fetchAgg = useCallback(async () => {
    try {
      const [w, s] = await Promise.all([
        fetch(`${API}/api/tickers/window_stats`),
        fetch(`${API}/api/tickers/spread`),
      ])
      if (!w.ok || !s.ok) throw new Error('agg')
      const [wj, sj] = await Promise.all([w.json(), s.json()])
      setWindowStats(wj.rows ?? [])
      setSpreadRows(sj.rows ?? [])
    } catch {
      setTickErr('poll failed')
    }
  }, [])

  usePoll(fetchHealth, 4000, [fetchHealth])
  usePoll(fetchTicks, 400, [fetchTicks])
  usePoll(fetchAgg, 800, [fetchAgg])

  useEffect(() => {
    fetchHealth().catch(() => setHealthErr('Backend unreachable'))
  }, [fetchHealth])

  const sparks = useMemo(
    () => buildProductSparklines(ticks, products, 64),
    [ticks, products],
  )

  const tapeRows = useMemo(() => {
    return [...ticks].sort((a, b) => String(b.Time).localeCompare(String(a.Time))).slice(0, 40)
  }, [ticks])

  const barData = useMemo(() => {
    return windowStats.map((r) => ({
      product: r.ProductId,
      ticks: r.TicksInWindow ?? 0,
      range: (r.High ?? 0) - (r.Low ?? 0),
      avg: r.AvgPrice,
    }))
  }, [windowStats])

  const multiLineData = useMemo(() => {
    const sparksLocal = buildProductSparklines(ticks, products, 96)
    const maxLen = Math.max(0, ...products.map((p) => sparksLocal[p]?.length ?? 0))
    const rows = []
    for (let i = 0; i < maxLen; i++) {
      const row = { i }
      for (const p of products) {
        const s = sparksLocal[p]
        if (!s?.length) continue
        const from = s.length - maxLen + i
        if (from >= 0 && from < s.length) row[p] = s[from].price
      }
      rows.push(row)
    }
    return rows
  }, [ticks, products])

  return (
    <div className="dashboard">
      <header className="header">
        <div>
          <h1>Streaming market data · Deephaven</h1>
          <p className="sub">
            Coinbase Exchange public WebSocket (
            <a
              href="https://docs.cdp.coinbase.com/exchange/websocket-feed/overview"
              target="_blank"
              rel="noreferrer"
            >
              ws-feed
            </a>
            ) is ingested into Deephaven ticking tables; this UI polls Flask snapshots of
            those tables.
          </p>
        </div>
        <div className="pills">
          {healthErr && <span className="pill err">{healthErr}</span>}
          {health && (
            <>
              <span className="pill live">live</span>
              <span className="pill">
                Deephaven UI port <span className="code">{health.deephaven_port}</span>
              </span>
            </>
          )}
          {tickErr && <span className="pill err">tick feed error</span>}
        </div>
      </header>

      <div className="cards">
        {spreadRows.map((r) => (
          <div key={r.ProductId} className="card">
            <div className="label">{r.ProductId}</div>
            <div className="value">{formatPrice(r.Price)}</div>
            <div className="small">
              spread {formatPrice(r.Spread)} · mid {formatPrice(r.Mid)}
            </div>
          </div>
        ))}
      </div>

      <div className="grid grid-2">
        <section className="panel">
          <h2>Price (last ticks)</h2>
          <p className="hint">Per-product sparklines refresh every poll; y-axis auto-scales.</p>
          <div className="spark-row">
            {products.map((p) => (
              <div key={p} className="spark">
                <div className="sym" style={{ color: PRODUCT_COLORS[p] ?? '#888' }}>
                  {p}
                </div>
                <div className="chart-wrap">
                  <ResponsiveContainer width="100%" height="100%">
                    <LineChart data={sparks[p]} margin={{ top: 4, right: 4, left: -28, bottom: 0 }}>
                      <CartesianGrid stroke="#2a3148" strokeDasharray="3 3" />
                      <XAxis dataKey="i" hide tick={{ fill: '#8b93a8', fontSize: 10 }} />
                      <YAxis
                        domain={['auto', 'auto']}
                        tick={{ fill: '#8b93a8', fontSize: 10 }}
                        width={48}
                      />
                      <Tooltip
                        contentStyle={{
                          background: '#1a2030',
                          border: '1px solid #2a3148',
                          borderRadius: 8,
                        }}
                        labelStyle={{ color: '#8b93a8' }}
                      />
                      <Line
                        type="monotone"
                        dataKey="price"
                        stroke={PRODUCT_COLORS[p] ?? '#3d8bfd'}
                        dot={false}
                        strokeWidth={2}
                        isAnimationActive={false}
                      />
                    </LineChart>
                  </ResponsiveContainer>
                </div>
              </div>
            ))}
          </div>
          <div className="chart-wrap tall">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={multiLineData} margin={{ top: 8, right: 12, left: 8, bottom: 4 }}>
                <CartesianGrid stroke="#2a3148" strokeDasharray="3 3" />
                <XAxis dataKey="i" tick={{ fill: '#8b93a8', fontSize: 11 }} />
                <YAxis tick={{ fill: '#8b93a8', fontSize: 11 }} domain={['auto', 'auto']} />
                <Tooltip
                  contentStyle={{
                    background: '#1a2030',
                    border: '1px solid #2a3148',
                    borderRadius: 8,
                  }}
                />
                <Legend />
                {products.map((p) => (
                  <Line
                    key={p}
                    type="monotone"
                    dataKey={p}
                    stroke={PRODUCT_COLORS[p] ?? '#888'}
                    dot={false}
                    strokeWidth={2}
                    connectNulls
                    isAnimationActive={false}
                  />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </div>
        </section>

        <section className="panel">
          <h2>Ring-buffer aggregation (Deephaven)</h2>
          <p className="hint">
            <code className="code">agg_by</code> on the ring table: tick count, min/max/avg price,
            and sum of last size over the retained window (~8k rows).
          </p>
          <div className="chart-wrap tall">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={barData} margin={{ top: 8, right: 12, left: 4, bottom: 4 }}>
                <CartesianGrid stroke="#2a3148" strokeDasharray="3 3" />
                <XAxis dataKey="product" tick={{ fill: '#8b93a8', fontSize: 11 }} />
                <YAxis yAxisId="left" tick={{ fill: '#8b93a8', fontSize: 11 }} />
                <YAxis yAxisId="right" orientation="right" tick={{ fill: '#8b93a8', fontSize: 11 }} />
                <Tooltip
                  contentStyle={{
                    background: '#1a2030',
                    border: '1px solid #2a3148',
                    borderRadius: 8,
                  }}
                />
                <Legend />
                <Bar yAxisId="left" dataKey="ticks" name="Ticks in window" radius={[4, 4, 0, 0]}>
                  {barData.map((_, i) => (
                    <Cell key={i} fill={i % 2 === 0 ? '#3d8bfd' : '#627eea'} />
                  ))}
                </Bar>
                <Bar yAxisId="right" dataKey="range" name="High−Low (window)" fill="#34d399" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
          <div className="tape" style={{ marginTop: '0.75rem' }}>
            <table>
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Ticks</th>
                  <th>High</th>
                  <th>Low</th>
                  <th>Avg</th>
                  <th>Σ size</th>
                </tr>
              </thead>
              <tbody>
                {windowStats.map((r) => (
                  <tr key={r.ProductId}>
                    <td>{r.ProductId}</td>
                    <td>{r.TicksInWindow}</td>
                    <td className="price">{formatPrice(r.High)}</td>
                    <td>{formatPrice(r.Low)}</td>
                    <td>{formatPrice(r.AvgPrice)}</td>
                    <td>{formatPrice(r.SumSize)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      </div>

      <section className="panel" style={{ marginTop: '1.25rem' }}>
        <h2>Live tape</h2>
        <p className="hint">Newest first; mirrors rows materialized in the Deephaven ring table.</p>
        <div className="tape">
          <table>
            <thead>
              <tr>
                <th>Time</th>
                <th>Product</th>
                <th>Price</th>
                <th>Bid</th>
                <th>Ask</th>
                <th>Side</th>
              </tr>
            </thead>
            <tbody>
              {tapeRows.map((t, idx) => (
                <tr key={`${t.Time}-${t.ProductId}-${idx}`}>
                  <td>{String(t.Time).replace('T', ' ').slice(0, 23)}</td>
                  <td>{t.ProductId}</td>
                  <td className="price">{formatPrice(t.Price)}</td>
                  <td>{formatPrice(t.BestBid)}</td>
                  <td>{formatPrice(t.BestAsk)}</td>
                  <td>{t.Side}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <p className="footer-note">
        Run backend: <code className="code">cd backend && python app.py</code>
        {' '}
        <span className="hint">(API :8082)</span> · frontend:{' '}
        <code className="code">cd frontend && npm run dev</code>{' '}
        <span className="hint">(dev server :5175)</span>
      </p>
    </div>
  )
}
