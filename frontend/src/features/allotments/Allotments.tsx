import { useEffect, useState } from 'react';
import HoldingInfo, { ExplanationSummary } from './HoldingInfo';
import { api, put, errorMessage } from '../../lib/api';
import { Confirm, Empty, Status, Table, type Actions } from '../../components/ui';
import type { Trace } from '../../lib/types';

export default function Allotments({ workspace: w, busy, mutate }: Actions) {
  const published = w.rounds.filter(r => r.published_sim_id);
  const [roundId, setRoundId] = useState(published.at(-1)?.round_id ?? 0),
    [trace, setTrace] = useState<Trace[]>([]),
    [error, setError] = useState('');
  const round = published.find(r => r.round_id === roundId) ?? published.at(-1);
  const allocation = w.allocations?.find(a => a.round_id === round?.round_id);
  const program = w.programs.find(p => p.program_id === allocation?.program_id);
  useEffect(() => {
    if (!round) return;
    let cancelled = false;
    api<Trace[]>(`/me/rounds/${round.round_id}/why-not`)
      .then(data => {
        if (!cancelled) {
          setTrace(data);
          setError('');
        }
      })
      .catch(e => {
        if (!cancelled) setError(errorMessage(e));
      });
    return () => {
      cancelled = true;
    };
  }, [round?.round_id]);
  return (
    <>
      <header className="page-heading">
        <h1>A clear answer to your choices.</h1>
        <p>Your allocation and the final seat-pool cutoffs behind it.</p>
      </header>
      <HoldingInfo workspace={w} />
      {!round ? (
        <Empty>No round is published yet. Your results will appear here after publication.</Empty>
      ) : (
        <>
          <label className="inline-select">
            Counselling round
            <select value={round.round_id} onChange={e => setRoundId(Number(e.target.value))}>
              {published.map(r => (
                <option key={r.round_id} value={r.round_id}>
                  Round {r.round_no}
                </option>
              ))}
            </select>
          </label>
          {allocation ? (
            <section className="allocation-letter">
              <div>
                <span className="muted">Your allocated program</span>
                <h2>{program?.name}</h2>
                <p>
                  {program?.institute} / {allocation.seat_category.replaceAll('_', ' ')} / preference{' '}
                  {allocation.pref_order}
                </p>
              </div>
              <Status value="ALLOTTED" />
            </section>
          ) : (
            <Empty>You were not allocated a seat in this round.</Empty>
          )}
          {allocation && (
            <section>
              <h2>Your response</h2>
              <p className="muted small">
                Freeze keeps this seat. Float allows a higher choice. Slide allows a higher choice at the same
                institute.
              </p>
              {allocation.decision && (
                <p>
                  Current response: <Status value={allocation.decision} />
                </p>
              )}
              <div className="actions wrap">
                {(['FREEZE', 'FLOAT', 'SLIDE', 'WITHDRAW'] as const).map(d => (
                  <Confirm
                    key={d}
                    label={d.toLowerCase().replace(/^./, x => x.toUpperCase())}
                    title={`Confirm ${d.toLowerCase()}?`}
                    disabled={
                      busy ||
                      round.status !== 'PUBLISHED' ||
                      new Date(round.response_deadline) <= new Date() ||
                      allocation.decision === 'WITHDRAW'
                    }
                    onConfirm={() =>
                      mutate(
                        () => put(`/me/rounds/${round.round_id}/response`, { decision: d }),
                        'Your response was recorded.',
                      )
                    }
                  >
                    <p>
                      {d === 'WITHDRAW'
                        ? 'Withdrawal is irreversible for this cycle. Your seat is released when the round closes.'
                        : `Your response will be saved as ${d.toLowerCase()}. You can change it before the response deadline unless you withdraw.`}
                    </p>
                  </Confirm>
                ))}
              </div>
            </section>
          )}
          <section>
            <h2>Why this allocation?</h2>
            <ExplanationSummary roundId={round.round_id} />
            {error && (
              <p role="alert" className="error">
                {error}
              </p>
            )}
            <Table
              rows={trace}
              label="Choice explanations"
              columns={[
                { label: 'Choice', render: t => `${t.pref_order}. ${t.program}` },
                { label: 'Institute', render: t => t.institute },
                { label: 'Pool', render: t => t.seat_category.replaceAll('_', ' ') },
                { label: 'Your rank', render: t => t.rank_used },
                { label: 'Closing rank', render: t => t.closing_rank ?? 'No seats filled' },
                { label: 'Decision', render: t => <Status value={t.outcome} /> },
              ]}
            />
          </section>
        </>
      )}
    </>
  );
}
