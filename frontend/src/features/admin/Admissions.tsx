import { useData } from '../../lib/useData';
import { post } from '../../lib/api';
import { Confirm, Status, Table, type Actions } from '../../components/ui';
import type { AdminDashboard } from '../../lib/types';
export default function Admissions({ workspace: w, busy, mutate }: Actions) {
  const { data, error, loading, reload } = useData<AdminDashboard>(`/admin/dashboard/${w.year}`, w);
  return (
    <>
      <header className="page-heading">
        <h1>Confirm the final place.</h1>
        <p>Check each current holding before confirming admission.</p>
      </header>
      {error && (
        <p role="alert" className="error">
          {error}
          <button onClick={reload}>Try again</button>
        </p>
      )}
      {loading ? (
        <p role="status">Loading current holdings…</p>
      ) : (
        <Table
          rows={data?.holdings ?? []}
          label="Current seat holdings"
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
            { label: 'Source', render: r => r.source.toLowerCase() },
            {
              label: 'Confirmation',
              render: r =>
                r.final ? (
                  <>
                    <Status value="CONFIRMED" />
                    <small>{r.confirmed_at && new Date(r.confirmed_at).toLocaleString()}</small>
                  </>
                ) : (
                  <Confirm
                    label="Confirm admission"
                    title="Confirm final admission?"
                    disabled={busy || w.rounds.some(r => r.status !== 'CLOSED')}
                    onConfirm={() =>
                      mutate(
                        () => post(`/admin/admissions/${w.year}/${r.student_id}/finalize`),
                        'Final admission confirmed.',
                      )
                    }
                  >
                    <p>
                      Confirm {r.student_name}'s {r.program} holding at {r.institute}. All ordinary rounds
                      must be closed.
                    </p>
                  </Confirm>
                ),
            },
          ]}
        />
      )}
    </>
  );
}
