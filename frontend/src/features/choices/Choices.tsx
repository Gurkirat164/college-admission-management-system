import { useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, Plus, X } from 'lucide-react';
import { put } from '../../lib/api';
import { Confirm, Empty, Status, type Actions } from '../../components/ui';

export default function Choices({ workspace: w, mutate, busy }: Actions) {
  const [choices, setChoices] = useState<number[]>(w.choices ?? []);
  useEffect(() => setChoices(w.choices ?? []), [w.choices]);
  const locked =
    !!w.application?.choices_locked_at || w.cycle.choices_locked || w.application?.status !== 'VERIFIED';
  const move = (i: number, offset: number) =>
    setChoices(old => {
      const next = [...old];
      [next[i], next[i + offset]] = [next[i + offset], next[i]];
      return next;
    });
  return (
    <>
      <header className="page-heading">
        <h1>Your choices, in your order.</h1>
        <p>List the programs you prefer most first.</p>
      </header>
      <div className="notice">
        Application <Status value={w.application?.status ?? 'DRAFT'} />
        {w.application?.crl_rank && <span>Common rank {w.application.crl_rank}</span>}
        <span>{w.application?.admission_category.replaceAll('_', ' ')}</span>
      </div>
      <div className="split">
        <section>
          <div className="section-heading">
            <h2>Preference list</h2>
            <span className="muted small">{choices.length} programs</span>
          </div>
          {!choices.length && <Empty>Add a program from the available list.</Empty>}
          <ol className="choice-list">
            {choices.map((id, i) => {
              const p = w.programs.find(p => p.program_id === id)!;
              return (
                <li key={id}>
                  <span className="choice-number">{i + 1}</span>
                  <div className="choice-name">
                    <strong>{p.code}</strong>
                    <span>{p.name}</span>
                    <small>{p.institute}</small>
                  </div>
                  <div className="actions compact">
                    <button
                      className="quiet icon-button"
                      aria-label={`Move ${p.code} ${p.institute} up`}
                      disabled={locked || i === 0 || busy}
                      onClick={() => move(i, -1)}
                    >
                      <ArrowUp size={16} />
                    </button>
                    <button
                      className="quiet icon-button"
                      aria-label={`Move ${p.code} ${p.institute} down`}
                      disabled={locked || i === choices.length - 1 || busy}
                      onClick={() => move(i, 1)}
                    >
                      <ArrowDown size={16} />
                    </button>
                    <button
                      className="quiet icon-button"
                      aria-label={`Remove ${p.code} ${p.institute}`}
                      disabled={locked || busy}
                      onClick={() => setChoices(choices.filter(x => x !== id))}
                    >
                      <X size={16} />
                    </button>
                  </div>
                </li>
              );
            })}
          </ol>
          <div className="actions">
            <button
              disabled={locked || busy}
              onClick={() =>
                mutate(
                  () => put(`/me/choices/${w.year}`, { program_ids: choices }),
                  'Your preference list was saved.',
                )
              }
            >
              {busy ? 'Saving…' : 'Save choices'}
            </button>
            <Confirm
              label="Lock choices"
              title="Lock your preference list?"
              disabled={locked || busy || !choices.length}
              onConfirm={() =>
                mutate(
                  () => put(`/me/choices/${w.year}?lock=true`, { program_ids: choices }),
                  'Your choices are locked.',
                )
              }
            >
              <p>
                You will not be able to edit this list after locking it. Your current order will be saved.
              </p>
            </Confirm>
          </div>
          {locked && (
            <p className="muted small">Choices require a verified application and an open choice window.</p>
          )}
        </section>
        <section className="program-catalog">
          <h2>Available programs</h2>
          {w.programs.map(p => (
            <div className="program-row" key={p.program_id}>
              <div>
                <strong>{p.code}</strong>
                <p>{p.name}</p>
                <small className="muted">
                  {p.institute} / {p.seats.reduce((n, s) => n + s.seats, 0)} places
                </small>
              </div>
              <button
                className="quiet icon-button"
                aria-label={`Add ${p.code} ${p.institute}`}
                disabled={locked || busy || choices.includes(p.program_id)}
                onClick={() => setChoices([...choices, p.program_id])}
              >
                <Plus size={18} />
              </button>
            </div>
          ))}
        </section>
      </div>
    </>
  );
}
