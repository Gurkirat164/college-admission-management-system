import { useEffect, useState } from 'react';
import { api, post, errorMessage } from '../../lib/api';
import { Confirm, Table, type Actions } from '../../components/ui';
import type { SpotPool } from '../../lib/types';
export default function Spot({ workspace: w, busy, mutate }: Actions) {
  const [pools, setPools] = useState<SpotPool[]>([]),
    [error, setError] = useState('');
  const load = () =>
    api<SpotPool[]>(`/spot/${w.year}`)
      .then(setPools)
      .catch(e => setError(errorMessage(e)));
  useEffect(() => {
    load();
  }, [w.year]);
  return (
    <>
      <header className="page-heading">
        <h1>The remaining places.</h1>
        <p>Eligible applicants without a current holding can accept an available seat.</p>
      </header>
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {w.user.role === 'ADMIN' && !pools.length && (
        <Confirm
          label="Open spot allocation"
          title="Initialize spot allocation?"
          disabled={busy}
          onConfirm={() =>
            mutate(async () => {
              await post(`/admin/spot/${w.year}/open`);
              await load();
            }, 'Spot allocation opened.')
          }
        >
          <p>All counselling rounds must be closed. Vacancies are calculated from retained holdings.</p>
        </Confirm>
      )}
      {w.user.role === 'ADMIN' && pools.some(p => p.status === 'OPEN') && (
        <Confirm
          label="Close spot allocation"
          title="Close all spot pools?"
          disabled={busy}
          onConfirm={() =>
            mutate(async () => {
              await post(`/admin/spot/${w.year}/close`);
              await load();
            }, 'Spot allocation closed.')
          }
        >
          <p>New spot acceptances will be rejected. Existing holdings remain recorded.</p>
        </Confirm>
      )}
      <Table
        rows={pools}
        label="Spot places"
        columns={[
          {
            label: 'Program',
            render: p => (
              <>
                <strong>{p.program}</strong>
                <small>{p.institute}</small>
              </>
            ),
          },
          { label: 'Pool', render: p => p.seat_category.replaceAll('_', ' ') },
          { label: 'Available', render: p => p.seats_left },
          {
            label: 'Action',
            render: p =>
              w.user.role === 'STUDENT' ? (
                <Confirm
                  label="Accept seat"
                  title="Accept this place?"
                  disabled={busy || p.seats_left < 1 || p.status !== 'OPEN'}
                  onConfirm={() =>
                    mutate(async () => {
                      const result = await post<{ status: string }>('/me/spot/accept', {
                        pool_id: p.pool_id,
                        idempotency_key: crypto.randomUUID(),
                      });
                      if (result.status !== 'ACCEPTED')
                        throw new Error(
                          'That place was just taken. Refresh availability and try another pool.',
                        );
                      await load();
                    }, 'Your spot place was accepted.')
                  }
                >
                  <p>
                    Accept {p.program} at {p.institute}. The server will recheck your eligibility and
                    available capacity.
                  </p>
                </Confirm>
              ) : (
                p.status
              ),
          },
        ]}
      />
    </>
  );
}
