import { categoryLabel } from '../../lib/api';
import { ArrowRight } from 'lucide-react';
import { Empty, Table } from '../../components/ui';
import type { RunDetails } from '../../lib/types';
export default function SimulationInsights({
  run,
  onPoolSelect,
}: {
  run: RunDetails;
  onPoolSelect: (pool: string) => void;
}) {
  const cutoffs = run.cutoffs ?? [],
    nodes = run.ripple?.nodes ?? [],
    max = Math.max(1, ...cutoffs.flatMap(c => [c.before ?? 0, c.after ?? 0]));
  const levels = [...new Set(nodes.map(n => n.depth))].sort((a, b) => a - b);
  return (
    <>
      <section className="insights">
        <div className="section-heading">
          <h3>Closing-rank shifts</h3>
          <span className="small muted">Each row compares the same seat pool.</span>
        </div>
        {cutoffs.length > 0 && (
          <svg
            className="cutoff-chart"
            role="img"
            aria-label="Before and after closing ranks by program and seat pool"
            viewBox={`0 0 760 ${Math.min(cutoffs.length, 15) * 38 + 30}`}
          >
            <title>Closing ranks. Muted bars show baseline; dark bars show scenario.</title>
            {cutoffs.slice(0, 15).map((c, i) => (
              <g key={`${c.program_id}/${c.seat_category}`} transform={`translate(0 ${i * 38 + 20})`}>
                <text x="0" y="6">
                  {c.program} {categoryLabel(c.seat_category)}
                </text>
                <rect
                  className="before-bar"
                  x="195"
                  y="-8"
                  width={((c.before ?? 0) / max) * 480}
                  height="7"
                />
                <rect className="after-bar" x="195" y="2" width={((c.after ?? 0) / max) * 480} height="7" />
                <text x="690" y="6">
                  {c.after ?? '—'}
                </text>
              </g>
            ))}
          </svg>
        )}
        <Table
          rows={cutoffs}
          label="Closing-rank comparisons"
          columns={[
            {
              label: 'Program',
              render: c => (
                <>
                  <strong>{c.program}</strong>
                  <small>{c.institute}</small>
                </>
              ),
            },
            { label: 'Pool', render: c => categoryLabel(c.seat_category) },
            { label: 'Before', render: c => c.before ?? 'Unfilled' },
            { label: 'After', render: c => c.after ?? 'Unfilled' },
            {
              label: 'Rank shift',
              render: c => (c.shift === null ? 'Not comparable' : `${c.shift > 0 ? '+' : ''}${c.shift}`),
            },
          ]}
        />
      </section>
      <section className="insights">
        <h3>Possible vacancy links</h3>
        <p className="small muted">
          {run.ripple?.method ?? 'Run an add-capacity scenario to explore connections.'} Select a pool to
          filter the student changes.
        </p>
        {nodes.length ? (
          <div className="ripple-scroll">
            {levels.map((depth, i) => (
              <div className="ripple-step" key={depth}>
                {i > 0 && <ArrowRight aria-hidden="true" size={18} />}
                <div>
                  <p className="small muted">
                    {depth === 0 ? 'Added capacity' : `Connection depth ${depth}`}
                  </p>
                  {nodes
                    .filter(n => n.depth === depth)
                    .map(n => (
                      <button className="quiet" key={n.pool} onClick={() => onPoolSelect(n.pool)}>
                        {n.program} / {categoryLabel(n.category)}
                        <small>{n.institute}</small>
                      </button>
                    ))}
                </div>
              </div>
            ))}
          </div>
        ) : (
          <Empty>No add-capacity links in this scenario.</Empty>
        )}
        <Table
          rows={run.ripple?.edges ?? []}
          label="Observed pool moves"
          columns={[
            { label: 'Capacity arriving in', render: e => e.source },
            { label: 'Vacancy left in', render: e => e.target },
            { label: 'Students moving', render: e => e.students },
          ]}
        />
      </section>
    </>
  );
}
