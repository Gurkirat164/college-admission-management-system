import type { Program } from '../../lib/types';
export default function ScenarioOptions({
  programs,
  withdrawn,
  setWithdrawn,
  rate,
  setRate,
  seed,
  setSeed,
}: {
  programs: Program[];
  withdrawn: number[];
  setWithdrawn: (v: number[]) => void;
  rate: number;
  setRate: (v: number) => void;
  seed: string;
  setSeed: (v: string) => void;
}) {
  return (
    <details className="scenario-options">
      <summary>Program and student withdrawals</summary>
      <fieldset>
        <legend>Withdraw a program in this scenario</legend>
        <div className="checkbox-list">
          {programs.map(p => (
            <label key={p.program_id}>
              <input
                type="checkbox"
                checked={withdrawn.includes(p.program_id)}
                onChange={e =>
                  setWithdrawn(
                    e.target.checked
                      ? [...withdrawn, p.program_id]
                      : withdrawn.filter(id => id !== p.program_id),
                  )
                }
              />
              {p.code} / {p.institute}
            </label>
          ))}
        </div>
      </fieldset>
      <div className="history-form">
        <label>
          Student withdrawal rate (%)
          <input
            type="number"
            min={0}
            max={100}
            step={0.1}
            value={rate}
            onChange={e => setRate(Number(e.target.value))}
          />
        </label>
        <label>
          Reproducible seed
          <input value={seed} maxLength={100} onChange={e => setSeed(e.target.value)} required={rate > 0} />
        </label>
      </div>
      <p className="small muted">
        The same snapshot and seed select the same students. Capacity removal cannot displace frozen
        commitments.
      </p>
    </details>
  );
}
