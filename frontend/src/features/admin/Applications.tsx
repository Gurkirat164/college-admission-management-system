import { useState } from 'react';
import { post, put } from '../../lib/api';
import { Status, Table, type Actions } from '../../components/ui';
export default function Applications({ workspace: w, busy, mutate }: Actions) {
  const [selected, setSelected] = useState<number | null>(null),
    [reason, setReason] = useState(''),
    [marks, setMarks] = useState(200),
    [rank, setRank] = useState(20),
    [category, setCategory] = useState('OPEN'),
    [catRank, setCatRank] = useState(1);
  const application = w.applications?.find(a => a.student_id === selected);
  return (
    <>
      <header className="page-heading">
        <h1>Review the record before the rank.</h1>
        <p>Verify documents, record exam results, and review eligibility.</p>
      </header>
      <Table
        rows={w.applications ?? []}
        label="Applications"
        columns={[
          { label: 'Student', render: a => a.full_name },
          { label: 'Category', render: a => a.admission_category.replaceAll('_', ' ') },
          { label: 'Common rank', render: a => a.crl_rank ?? 'Not recorded' },
          { label: 'Status', render: a => <Status value={a.status} /> },
          {
            label: 'Review',
            render: a => (
              <button
                className="quiet"
                onClick={() => {
                  setSelected(a.student_id);
                  setReason(a.review_reason ?? '');
                  setMarks(a.total_marks ?? 200);
                  setRank(a.crl_rank ?? 20);
                  setCategory(a.admission_category);
                  setCatRank(a.cat_rank ?? 1);
                }}
              >
                Open application
              </button>
            ),
          },
        ]}
      />
      {application && (
        <section className="review-panel">
          <h2>{application.full_name}</h2>
          <h3>Documents</h3>
          <Table
            rows={application.documents ?? []}
            label="Application documents"
            columns={[
              {
                label: 'Document',
                render: d => <a href={`/api/v1/documents/${d.document_id}`}>{d.original_name}</a>,
              },
              { label: 'State', render: d => <Status value={d.status} /> },
              {
                label: 'Action',
                render: d => (
                  <div className="actions">
                    <button
                      className="quiet"
                      disabled={busy || w.cycle.choices_locked}
                      onClick={() =>
                        mutate(
                          () =>
                            post(`/admin/documents/${d.document_id}/review`, {
                              approve: true,
                              reason: 'Verified against synthetic exam record',
                            }),
                          'Document verified.',
                        )
                      }
                    >
                      Verify
                    </button>
                    <button
                      className="quiet"
                      disabled={busy || w.cycle.choices_locked || reason.trim().length < 3}
                      onClick={() =>
                        mutate(
                          () => post(`/admin/documents/${d.document_id}/review`, { approve: false, reason }),
                          'Document rejected with a reason.',
                        )
                      }
                    >
                      Reject
                    </button>
                  </div>
                ),
              },
            ]}
          />
          <form
            className="exam-form"
            onSubmit={e => {
              e.preventDefault();
              mutate(
                () =>
                  put(`/admin/applications/${w.year}/${selected}/exam`, {
                    category,
                    total_marks: marks,
                    crl_rank: rank,
                    cat_rank: category === 'OPEN' ? null : catRank,
                  }),
                'Exam record saved.',
              );
            }}
          >
            <label>
              Marks out of 300
              <input
                required
                type="number"
                min={0}
                max={300}
                value={marks}
                onChange={e => setMarks(Number(e.target.value))}
              />
            </label>
            <label>
              Common rank
              <input
                required
                type="number"
                min={1}
                value={rank}
                onChange={e => setRank(Number(e.target.value))}
              />
            </label>
            <label>
              Category
              <select value={category} onChange={e => setCategory(e.target.value)}>
                {['OPEN', 'EWS', 'OBC_NCL', 'SC', 'ST'].map(c => (
                  <option key={c}>{c}</option>
                ))}
              </select>
            </label>
            {category !== 'OPEN' && (
              <label>
                Category rank
                <input
                  required
                  type="number"
                  min={1}
                  value={catRank}
                  onChange={e => setCatRank(Number(e.target.value))}
                />
              </label>
            )}
            <button disabled={busy || w.cycle.choices_locked}>Save exam record</button>
          </form>
          <label>
            Review reason
            <textarea
              value={reason}
              maxLength={500}
              onChange={e => setReason(e.target.value)}
              placeholder="Record the reason for your decision."
            />
          </label>
          <div className="actions">
            <button
              disabled={busy || w.cycle.choices_locked}
              onClick={() =>
                mutate(
                  () => post(`/admin/applications/${w.year}/${selected}/review`, { approve: true, reason }),
                  'Application verified.',
                )
              }
            >
              Verify application
            </button>
            <button
              className="quiet"
              disabled={busy || w.cycle.choices_locked || reason.trim().length < 3}
              onClick={() =>
                mutate(
                  () => post(`/admin/applications/${w.year}/${selected}/review`, { approve: false, reason }),
                  'Application rejected with a reason.',
                )
              }
            >
              Reject application
            </button>
          </div>
        </section>
      )}
    </>
  );
}
