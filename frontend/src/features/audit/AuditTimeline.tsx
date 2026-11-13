import { useState } from 'react';
import { post } from '../../lib/api';
import { useData } from '../../lib/useData';
import { Status, Table, type Actions } from '../../components/ui';
interface Events {
  total: number;
  events: {
    seq: number;
    recorded_at: string;
    entity: string;
    operation: string;
    actor_id: string | null;
    hash: string;
  }[];
}
export default function AuditTimeline({ workspace: w, busy, mutate }: Actions) {
  const [offset, setOffset] = useState(0),
    [seq, setSeq] = useState(1),
    [hash, setHash] = useState(''),
    [match, setMatch] = useState<boolean | null>(null);
  const { data, error, loading } = useData<Events>(`/audit/events?offset=${offset}`, w);
  return (
    <>
      <section>
        <h2>Compare a protected checkpoint</h2>
        <p className="small muted">Use a sequence and hash saved independently of this database.</p>
        <form
          className="history-form"
          onSubmit={e => {
            e.preventDefault();
            mutate(async () => {
              const result = await post<{ matches: boolean }>('/audit/checkpoint', { seq, hash });
              setMatch(result.matches);
            }, 'Checkpoint comparison completed.');
          }}
        >
          <label>
            Checkpoint sequence
            <input
              type="number"
              min={1}
              required
              value={seq}
              onChange={e => setSeq(Number(e.target.value))}
            />
          </label>
          <label>
            SHA-256 hash
            <input
              required
              pattern="[0-9a-f]{64}"
              value={hash}
              onChange={e => setHash(e.target.value)}
              minLength={64}
              maxLength={64}
            />
          </label>
          <button disabled={busy}>Compare checkpoint</button>
        </form>
        {match !== null && (
          <p>
            <Status value={match ? 'PASS' : 'FAILED'} />
            {match ? ' The checkpoint exists and matches.' : ' The checkpoint does not match this chain.'}
          </p>
        )}
      </section>
      <section>
        <h2>Recent audit events</h2>
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        {loading ? (
          <p role="status">Loading event metadata…</p>
        ) : (
          <>
            <Table
              rows={data?.events ?? []}
              label="Audit events"
              columns={[
                { label: 'Sequence', render: r => r.seq },
                { label: 'Recorded', render: r => new Date(r.recorded_at).toLocaleString() },
                { label: 'Entity', render: r => r.entity },
                { label: 'Operation', render: r => r.operation.toLowerCase() },
                { label: 'Actor ID', render: r => r.actor_id ?? 'Setup' },
              ]}
            />
            <div className="actions">
              <button
                className="quiet"
                disabled={!offset}
                onClick={() => setOffset(Math.max(0, offset - 25))}
              >
                Newer events
              </button>
              <button
                className="quiet"
                disabled={offset + 25 >= (data?.total ?? 0)}
                onClick={() => setOffset(offset + 25)}
              >
                Older events
              </button>
              <span className="small muted">{data?.total ?? 0} recorded events</span>
            </div>
          </>
        )}
      </section>
    </>
  );
}
