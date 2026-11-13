import { useEffect, useState } from 'react';
import MockForecast from './MockForecast';
import { api, errorMessage, categoryLabel } from '../../lib/api';
import { Status, Table, type Actions } from '../../components/ui';
import type { Chance } from '../../lib/types';
export default function Predictor({ workspace: w }: Actions) {
  const [rows, setRows] = useState<Chance[]>([]),
    [error, setError] = useState(''),
    [loading, setLoading] = useState(true);
  useEffect(() => {
    api<Chance[]>(`/me/chances/${w.year}`)
      .then(setRows)
      .catch(e => setError(errorMessage(e)))
      .finally(() => setLoading(false));
  }, [w.year]);
  return (
    <>
      <header className="page-heading">
        <h1>Your chances</h1>
      </header>
      <MockForecast workspace={w} />
      <div className="notice">
        Synthetic historical data. These bands are heuristics, not admission probabilities or guarantees.
      </div>
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {loading ? (
        <p role="status">Loading historical bands…</p>
      ) : (
        <Table
          rows={rows}
          label="Chance bands"
          columns={[
            {
              label: 'Program',
              render: r => (
                <>
                  <strong>{r.program}</strong>
                  <small>{r.institute}</small>
                </>
              ),
            },
            { label: 'Pool', render: r => categoryLabel(r.seat_category) },
            { label: 'Your rank', render: r => r.your_rank },
            { label: 'Projected close', render: r => r.projected_close },
            {
              label: 'Source',
              render: r => `${r.years_of_data} years, ${r.synthetic ? 'synthetic' : 'imported/mixed'}`,
            },
            { label: 'Band', render: r => <Status value={r.band} /> },
          ]}
        />
      )}
    </>
  );
}
