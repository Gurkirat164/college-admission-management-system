import { useState } from 'react';
import ScenarioOptions from './ScenarioOptions';
import SimulationInsights from './SimulationInsights';
import { post, put, api, friendly } from '../../lib/api';
import { Empty, Status, Table, type Actions } from '../../components/ui';
import type { RunDetails } from '../../lib/types';

export function RunResults({ run }: { run: RunDetails }) {
  const [filter, setFilter] = useState('ALL'),
    [poolFilter, setPoolFilter] = useState('');
  const changed = run.diff.filter(
    d =>
      (filter === 'ALL' ? d.change_type !== 'UNCHANGED' : d.change_type === filter) &&
      (!poolFilter ||
        `${d.sim_program}/${d.sim_category}` === poolFilter ||
        `${d.base_program}/${d.base_category}` === poolFilter),
  );
  return (
    <section className="run-results">
      <div className="section-heading">
        <div>
          <h2>{run.label}</h2>
          <p className="small muted">
            Run #{run.sim_id} / snapshot #{run.snapshot_id} / {run.duration_ms} ms
          </p>
        </div>
        <Status value={run.checks.stability ?? 'NOT_CHECKED'} />
      </div>
      <div className="run-facts">
        <span>
          <strong>{run.summary.assigned ?? 0}</strong> allocated
        </span>
        <span>
          <strong>{run.summary.applicants ?? 0}</strong> applicants
        </span>
        <span>
          Capacity <Status value={run.checks.capacity ?? 'NOT_CHECKED'} />
        </span>
        <span>
          Add-only check <Status value={run.checks.monotonicity ?? 'NOT_APPLICABLE'} />
        </span>
      </div>
      {run.diff.length > 0 && (
        <>
          <h3>What changed</h3>
          <div className="result-tools">
            <label>
              Change type
              <select value={filter} onChange={e => setFilter(e.target.value)}>
                {['ALL', 'UPGRADED', 'NEW_SEAT', 'POOL_SHIFT', 'LOST_SEAT', 'DOWNGRADED', 'UNCHANGED'].map(
                  x => (
                    <option key={x} value={x}>
                      {friendly(x)}
                    </option>
                  ),
                )}
              </select>
            </label>
            <a className="download-link" href={`/api/v1/simulations/${run.sim_id}/export`}>
              Export masked CSV
            </a>
            {poolFilter && (
              <button className="quiet" onClick={() => setPoolFilter('')}>
                Clear pool filter
              </button>
            )}
          </div>
          <Table
            rows={changed}
            label="Allocation changes"
            columns={[
              { label: 'Student', render: d => d.student_name },
              { label: 'Before', render: d => d.base_code ?? 'No seat' },
              { label: 'After', render: d => d.sim_code ?? 'No seat' },
              { label: 'Change', render: d => <Status value={d.change_type} /> },
            ]}
          />
        </>
      )}
      <SimulationInsights run={run} onPoolSelect={setPoolFilter} />
      <h3>Allocation results</h3>
      <Table
        rows={run.results}
        label="Allocation results"
        columns={[
          { label: 'Student', render: r => r.student_name },
          {
            label: 'Program',
            render: r => (
              <>
                <strong>{r.program}</strong>
                <small>{r.institute}</small>
              </>
            ),
          },
          { label: 'Pool', render: r => r.seat_category.replaceAll('_', ' ') },
          { label: 'Preference', render: r => r.pref_order },
          { label: 'Rank used', render: r => r.rank_used },
        ]}
      />
    </section>
  );
}
export default function Sandbox({ workspace: w, busy, mutate }: Actions) {
  const bases = (w.simulations ?? []).filter(
    s => Object.keys(s.scenario).filter(k => k !== 'label').length === 0,
  );
  const [base, setBase] = useState<number>(bases[0]?.sim_id ?? 0),
    [program, setProgram] = useState(w.programs[0]?.program_id ?? 1),
    [pool, setPool] = useState('OPEN'),
    [delta, setDelta] = useState(1),
    [label, setLabel] = useState('Add a place to CSE'),
    [result, setResult] = useState<RunDetails | null>(null);
  const [withdrawn, setWithdrawn] = useState<number[]>([]),
    [rate, setRate] = useState(0),
    [seed, setSeed] = useState('demo-2026');
  const selected = bases.find(b => b.sim_id === base) ?? bases[0];
  async function simulate() {
    if (!selected) return;
    setResult(
      await post<RunDetails>('/simulations', {
        round_id: selected.round_id,
        base_sim_id: selected.sim_id,
        scenario: {
          label,
          seat_changes: [{ program_id: program, seat_category: pool, delta }],
          ...(withdrawn.length ? { withdraw_programs: withdrawn } : {}),
          ...(rate > 0 ? { withdrawal_rate: rate / 100, seed } : {}),
        },
      }),
    );
  }
  return (
    <>
      <header className="page-heading">
        <h1>Change the plan. See the effect.</h1>
        <p>Compare a scenario against the exact inputs of a saved baseline.</p>
      </header>
      {!bases.length ? (
        <Empty>
          <h2>Start with a baseline</h2>
          <p>Run the current choices once before changing capacity.</p>
          <button
            disabled={busy}
            onClick={() =>
              mutate(async () => {
                const run = await post<RunDetails>('/simulations', {
                  round_id: w.rounds[0].round_id,
                  scenario: {},
                });
                setBase(run.sim_id);
                setResult(run);
              }, 'Baseline saved.')
            }
          >
            Create baseline
          </button>
        </Empty>
      ) : (
        <form
          className="scenario-form"
          onSubmit={e => {
            e.preventDefault();
            mutate(simulate, 'Scenario completed. Live seat capacity was unchanged.');
          }}
        >
          <label>
            Baseline
            <select value={selected?.sim_id} onChange={e => setBase(Number(e.target.value))}>
              {bases.map(s => (
                <option value={s.sim_id} key={s.sim_id}>
                  Run #{s.sim_id}: {s.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Program
            <select value={program} onChange={e => setProgram(Number(e.target.value))}>
              {w.programs.map(p => (
                <option value={p.program_id} key={p.program_id}>
                  {p.code} / {p.institute}
                </option>
              ))}
            </select>
          </label>
          <label>
            Seat pool
            <select value={pool} onChange={e => setPool(e.target.value)}>
              {['OPEN', 'EWS', 'OBC_NCL', 'SC', 'ST'].map(x => (
                <option key={x}>{x}</option>
              ))}
            </select>
          </label>
          <label>
            Seat change
            <input
              type="number"
              min={-10000}
              max={10000}
              value={delta}
              onChange={e => setDelta(Number(e.target.value))}
              required
            />
          </label>
          <ScenarioOptions
            programs={w.programs}
            withdrawn={withdrawn}
            setWithdrawn={setWithdrawn}
            rate={rate}
            setRate={setRate}
            seed={seed}
            setSeed={setSeed}
          />
          <label className="scenario-label">
            Scenario name
            <input value={label} maxLength={100} onChange={e => setLabel(e.target.value)} required />
          </label>
          <button disabled={busy} aria-busy={busy}>
            {busy ? 'Solving…' : 'Run scenario'}
          </button>
        </form>
      )}
      {result && <RunResults run={result} />}
      <section>
        <h2>Saved runs</h2>
        <Table
          label="Saved runs"
          rows={w.simulations ?? []}
          columns={[
            { label: 'Run', render: s => `#${s.sim_id}` },
            { label: 'Scenario', render: s => s.label },
            { label: 'Status', render: s => friendly(s.is_published ? 'PUBLISHED' : 'SIMULATION') },
            { label: 'Stability', render: s => <Status value={s.checks.stability ?? 'NOT_CHECKED'} /> },
            {
              label: 'Retention',
              render: s => (
                <button
                  className="quiet"
                  disabled={busy || s.is_published}
                  onClick={() =>
                    mutate(
                      () => put(`/simulations/${s.sim_id}/pin`, { pinned: !s.pinned }),
                      s.pinned ? 'Run unpinned.' : 'Run pinned against cleanup.',
                    )
                  }
                >
                  {s.is_published ? 'Published' : s.pinned ? 'Unpin run' : 'Keep run'}
                </button>
              ),
            },
            {
              label: 'Details',
              render: s => (
                <button
                  className="quiet"
                  disabled={busy}
                  onClick={() =>
                    mutate(async () => {
                      setResult(await api<RunDetails>(`/simulations/${s.sim_id}`));
                    }, 'Saved run loaded.')
                  }
                >
                  View run
                </button>
              ),
            },
          ]}
        />
      </section>
    </>
  );
}
