import type { ReactNode } from 'react';
import { categoryLabel } from '../../lib/api';
import type { OverviewData } from '../../lib/types';

const CATEGORY_ORDER = ['OPEN', 'EWS', 'OBC_NCL', 'SC', 'ST'];
const pct = (value: number, max: number) => (max <= 0 ? 0 : Math.min(100, (value / max) * 100));
const campus = (institute: string) => institute.split(' ')[0];
const ordinal = (n: number) => {
  const tens = n % 100;
  if (tens >= 11 && tens <= 13) return `${n}th`;
  return `${n}${({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th'}`;
};

/** One chart section: the same heading, subtitle and top rule as every other Overview section. */
function Panel({
  id,
  title,
  sub,
  children,
}: {
  id: string;
  title: string;
  sub: string;
  children: ReactNode;
}) {
  return (
    <section aria-labelledby={id}>
      <div className="overview-section-head">
        <h2 id={id}>{title}</h2>
        <span>{sub}</span>
      </div>
      {children}
    </section>
  );
}

interface Row {
  key: string;
  label: string;
  value: string;
  marks: ReactNode;
}

/** Label | track | value rows, drawn on the same guide lines as the rank chart. */
function Rows({ rows, label }: { rows: Row[]; label: string }) {
  return (
    <div className="metric-rows" role="list" aria-label={label}>
      {rows.map(row => (
        <div className="metric-row" role="listitem" key={row.key}>
          <span className="metric-label">{row.label}</span>
          <span className="metric-track" aria-hidden="true">
            <span className="metric-guide" />
            {row.marks}
          </span>
          <span className="metric-value">{row.value}</span>
        </div>
      ))}
    </div>
  );
}

export default function Analytics({ data, children }: { data: OverviewData; children?: ReactNode }) {
  // Closing ranks: opening to closing rank per filled pool, in program order.
  const pools = data.pools
    .map(pool => {
      const ranks = data.seats
        .filter(s => s.program_id === pool.program_id && s.seat_category === pool.seat_category)
        .map(s => s.rank_used);
      return { pool, open: Math.min(...ranks), close: Math.max(...ranks), filled: ranks.length };
    })
    .filter(p => p.filled > 0)
    .sort(
      (a, b) =>
        a.pool.program_id - b.pool.program_id ||
        CATEGORY_ORDER.indexOf(a.pool.seat_category) - CATEGORY_ORDER.indexOf(b.pool.seat_category),
    );
  const maxRank = Math.max(1, ...pools.map(p => p.close));
  const x = (rank: number) => (maxRank === 1 ? 0 : ((rank - 1) / (maxRank - 1)) * 100);

  // Choice received: placed applicants by the preference that won them a seat.
  const maxPref = Math.max(1, ...data.seats.map(s => s.pref_order));
  const byPref = Array.from(
    { length: maxPref },
    (_, i) => data.seats.filter(s => s.pref_order === i + 1).length,
  );
  const placed = data.seats.length;
  const choiceRows: Row[] = byPref.map((count, i) => ({
    key: `p${i}`,
    label: `${ordinal(i + 1)} choice`,
    value: placed ? `${count} · ${Math.round((count / placed) * 100)}%` : '0',
    marks: count > 0 && (
      <span className="metric-bar" style={{ width: `${pct(count, Math.max(...byPref))}%` }} />
    ),
  }));
  if (data.unplaced.length)
    choiceRows.push({
      key: 'none',
      label: 'Not placed',
      value: String(data.unplaced.length),
      marks: (
        <span
          className="metric-bar hollow"
          style={{ width: `${pct(data.unplaced.length, Math.max(...byPref))}%` }}
        />
      ),
    });

  // Demand: first-choice applicants against seats; the tick marks capacity.
  const demandMax = Math.max(1, ...data.demand.map(d => Math.max(d.first_choice, d.seats)));
  const demandRows: Row[] = data.demand.map(d => ({
    key: String(d.program_id),
    label: `${d.code} ${campus(d.institute)}`,
    value: `${d.first_choice} / ${d.seats}`,
    marks: (
      <>
        {d.first_choice > 0 && (
          <span className="metric-bar" style={{ width: `${pct(d.first_choice, demandMax)}%` }} />
        )}
        <span className="metric-tick" style={{ left: `${pct(d.seats, demandMax)}%` }} />
      </>
    ),
  }));
  const busiest = data.demand[0];

  // Funnel: applicants reaching each stage, as a share of everyone who applied.
  const stages: [string, number][] = [
    ['Applied', data.funnel.applied],
    ['Submitted', data.funnel.submitted],
    ['Verified', data.funnel.verified],
    ['Ranked', data.funnel.ranked],
    ['Chose programs', data.funnel.chose],
    ['Placed', placed],
  ];

  // Solver runs: duration of each recent live run.
  const runs = data.runs;
  const durations = runs.map(r => r.duration_ms).sort((a, b) => a - b);
  const median = durations.length ? durations[Math.floor((durations.length - 1) / 2)] : 0;
  const slowest = Math.max(1, ...durations);

  return (
    <div className="overview-analytics">
      {pools.length > 0 && (
        <Panel
          id="closing-ranks"
          title="Closing ranks by pool"
          sub="Opening to closing rank; reserved rows use category rank"
        >
          <Rows
            label="Closing ranks by pool"
            rows={pools.map(p => ({
              key: `${p.pool.program_id}:${p.pool.seat_category}`,
              label: `${p.pool.code} ${campus(p.pool.institute)} · ${categoryLabel(p.pool.seat_category)}`,
              value: p.open === p.close ? String(p.close) : `${p.open}–${p.close}`,
              marks: (
                <span
                  className={`metric-range ${p.pool.seat_category === 'OPEN' ? '' : 'reserved'}`}
                  style={{ left: `${x(p.open)}%`, width: `${x(p.close) - x(p.open)}%` }}
                />
              ),
            }))}
          />
        </Panel>
      )}

      {placed > 0 && (
        <Panel
          id="choice-received"
          title="Choice received"
          sub={`${byPref[0]} of ${placed} placed applicants got their first choice`}
        >
          <Rows label="Choice received" rows={choiceRows} />
        </Panel>
      )}

      {data.demand.length > 0 && (
        <Panel
          id="demand"
          title="Demand against seats"
          sub={
            busiest && busiest.seats > 0 && busiest.first_choice > busiest.seats
              ? `${busiest.code} ${campus(busiest.institute)} has ${(busiest.first_choice / busiest.seats).toFixed(1)} first-choice applicants per seat`
              : 'First-choice applicants per program; the tick marks seats'
          }
        >
          <Rows label="Demand against seats" rows={demandRows} />
        </Panel>
      )}

      <Panel id="funnel" title="Application funnel" sub="Applicants reaching each stage this cycle">
        <Rows
          label="Application funnel"
          rows={stages.map(([label, value]) => ({
            key: label,
            label,
            value: String(value),
            marks: value > 0 && (
              <span className="metric-bar" style={{ width: `${pct(value, data.funnel.applied)}%` }} />
            ),
          }))}
        />
      </Panel>

      {runs.length > 0 && (
        <Panel
          id="solver-runs"
          title="Solver runs"
          sub={`Last ${runs.length} live runs · median ${median} ms · slowest ${slowest} ms`}
        >
          <div className="run-columns" role="list" aria-label="Solver run durations">
            {runs.map(run => (
              <div
                className="run-column"
                role="listitem"
                key={run.sim_id}
                aria-label={`Run ${run.sim_id}: ${run.duration_ms} ms`}
              >
                <span className="run-bar-track">
                  <span className="run-bar" style={{ height: `${pct(run.duration_ms, slowest)}%` }} />
                </span>
                <span className="run-id">#{run.sim_id}</span>
              </div>
            ))}
          </div>
        </Panel>
      )}
      {children}
    </div>
  );
}
