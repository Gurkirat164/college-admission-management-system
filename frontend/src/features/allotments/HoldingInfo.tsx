import { categoryLabel } from '../../lib/api';
import { Status } from '../../components/ui';
import { useData } from '../../lib/useData';
import type { Holding, Workspace } from '../../lib/types';
export default function HoldingInfo({ workspace: w }: { workspace: Workspace }) {
  const { data, error } = useData<Holding>(`/me/holding/${w.year}`, w);
  if (error)
    return (
      <p className="error" role="alert">
        {error}
      </p>
    );
  if (!data) return null;
  return (
    <section className="holding-summary">
      <h2>Current seat holding</h2>
      <p>
        {data.program} / {data.institute} / {categoryLabel(data.seat_category)}
      </p>
      <p className="small muted">Acquired through {data.source.toLowerCase()} allocation.</p>
      <Status value={data.final ? 'CONFIRMED' : 'HELD'} />
      {data.confirmed_at && <p>Confirmed {new Date(data.confirmed_at).toLocaleString()}</p>}
    </section>
  );
}
export function ExplanationSummary({ roundId }: { roundId: number }) {
  const { data } = useData<{ outcome: string; reason_code: string | null }>(
    `/me/rounds/${roundId}/explanation-summary`,
  );
  if (!data) return null;
  const reasons: Record<string, string> = {
    APPLICATION_NOT_VERIFIED: 'The application was not verified when this round was captured.',
    WITHDRAWN: 'This application was withdrawn from the run.',
    NO_ELIGIBLE_CHOICES: 'No eligible choices were available in the captured preference list.',
    ALL_ELIGIBLE_CHOICES_FULL: 'Every eligible choice was full under the recorded priorities.',
  };
  return data.outcome === 'ALLOTTED' ? null : (
    <p className="notice">{reasons[data.reason_code ?? ''] ?? data.outcome.toLowerCase()}</p>
  );
}
