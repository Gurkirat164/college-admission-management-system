import { useState } from 'react';
import RoundSettings from './RoundSettings';
import { post, put } from '../../lib/api';
import { Confirm, Status, Table, type Actions } from '../../components/ui';
import type { RunDetails } from '../../lib/types';
import { RunResults } from '../sandbox/Sandbox';

export default function Rounds({ workspace: w, mutate, busy }: Actions) {
  const [result, setResult] = useState<RunDetails | null>(null);
  return (
    <>
      <header className="page-heading">
        <h1>Every seat, accounted for.</h1>
        <p>Review capacity, lock choices, and publish a verified allocation.</p>
      </header>
      <RoundSettings workspace={w} mutate={mutate} busy={busy} />
      <section className="round-controls">
        <h2>Counselling rounds</h2>
        {w.rounds.map(r => (
          <div className="round-row" key={r.round_id}>
            <div>
              <strong>Round {r.round_no}</strong>
              <p className="small muted">
                Responses until{' '}
                {new Date(r.response_deadline).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })} IST
              </p>
            </div>
            <Status value={r.status} />
            <div className="actions">
              <button
                className="quiet"
                disabled={busy}
                onClick={() =>
                  mutate(async () => {
                    setResult(await post<RunDetails>('/simulations', { round_id: r.round_id, scenario: {} }));
                  }, 'Baseline allocation completed.')
                }
              >
                Run baseline
              </button>
              {r.status === 'CHOICES_OPEN' && (
                <Confirm
                  label="Lock round"
                  title="Lock choices for this cycle?"
                  disabled={busy}
                  onConfirm={() =>
                    mutate(() => post(`/admin/rounds/${r.round_id}/lock`), 'Choices and capacity are locked.')
                  }
                >
                  <p>This closes choice editing and seat-matrix changes for this cycle.</p>
                </Confirm>
              )}
              {r.status === 'LOCKED' && (
                <Confirm
                  label="Publish allocation"
                  title="Publish this round?"
                  disabled={busy}
                  onConfirm={() =>
                    mutate(async () => {
                      setResult(
                        await post<RunDetails>(`/admin/rounds/${r.round_id}/publish`, {
                          idempotency_key: crypto.randomUUID(),
                        }),
                      );
                    }, 'The allocation is published.')
                  }
                >
                  <p>
                    Results become visible to students. Publication runs fresh live inputs and commits only
                    after its checks pass.
                  </p>
                </Confirm>
              )}
              {r.status === 'PUBLISHED' && (
                <Confirm
                  label="Close round"
                  title="Close the response window?"
                  disabled={busy || new Date(r.response_deadline) > new Date()}
                  onConfirm={() =>
                    mutate(
                      () => post(`/admin/rounds/${r.round_id}/close`),
                      'Round closed; missing responses defaulted to freeze.',
                    )
                  }
                >
                  <p>
                    After the deadline, missing responses become FREEZE and withdrawals release their
                    holdings.
                  </p>
                </Confirm>
              )}
            </div>
          </div>
        ))}
      </section>
      <section>
        <div className="section-heading">
          <h2>Seat matrix</h2>
          <span className="small muted">
            {w.cycle.choices_locked ? 'Locked for this cycle' : 'Editable before locking'}
          </span>
        </div>
        <Table
          label="Seat pools"
          rows={w.programs.flatMap(p => p.seats.map(s => ({ ...s, code: p.code, institute: p.institute })))}
          columns={[
            {
              label: 'Program',
              render: p => (
                <>
                  <strong>{p.code}</strong>
                  <small>{p.institute}</small>
                </>
              ),
            },
            { label: 'Pool', render: p => p.seat_category.replaceAll('_', ' ') },
            {
              label: 'Capacity',
              render: p => (
                <SeatEditor
                  seats={p.seats}
                  disabled={busy || w.cycle.choices_locked}
                  save={seats =>
                    mutate(
                      () => put(`/admin/seat-matrix/${w.year}/${p.program_id}/${p.seat_category}`, { seats }),
                      'Seat capacity updated.',
                    )
                  }
                />
              ),
            },
          ]}
        />
      </section>
      {result && <RunResults run={result} />}
    </>
  );
}
function SeatEditor({
  seats,
  disabled,
  save,
}: {
  seats: number;
  disabled: boolean;
  save: (seats: number) => void;
}) {
  const [value, setValue] = useState(seats);
  return (
    <div className="actions compact">
      <input
        className="seat-input"
        aria-label="Seat capacity"
        type="number"
        min={0}
        max={10000}
        value={value}
        disabled={disabled}
        onChange={e => setValue(Number(e.target.value))}
      />
      <button
        className="quiet"
        disabled={disabled || value === seats || !Number.isInteger(value) || value < 0 || value > 10000}
        onClick={() => save(value)}
      >
        Save
      </button>
    </div>
  );
}
