import { useState } from 'react';
import { api } from '../../lib/api';
import { Confirm, Table, type Actions } from '../../components/ui';
interface Preview {
  input_revision: number;
  payload_hash: string;
  imported_rows: number;
  cohort_size: number;
  committed: boolean;
  results: {
    student_id: number;
    dob: string;
    category: string;
    total_marks: number;
    crl_rank: number;
    cat_rank: number;
  }[];
}
export default function Imports({ workspace: w, busy, mutate }: Actions) {
  const [exam, setExam] = useState<File | null>(null),
    [history, setHistory] = useState<File | null>(null),
    [preview, setPreview] = useState<Preview | null>(null);
  function examImport(commit: boolean) {
    if (!exam) return Promise.resolve();
    const data = new FormData();
    data.append('file', exam);
    return api<Preview>(
      `/admin/exams/${w.year}/import?commit=${commit}${commit ? `&expected_revision=${preview?.input_revision}` : ''}`,
      { method: 'POST', body: data },
    ).then(setPreview);
  }
  return (
    <>
      <header className="page-heading">
        <h1>Import marks. Verify the order.</h1>
        <p>Preview deterministic ranks before changing admission records.</p>
      </header>
      <section>
        <h2>Exam results</h2>
        <p className="small muted">
          Tie-break: total marks, maths, physics, earlier birth date, then student ID. Subject marks are out
          of 100.
        </p>
        <a href="/samples/exams.csv" download>
          Download example exam CSV
        </a>
        <label>
          Exam CSV
          <input
            type="file"
            accept=".csv,text/csv"
            disabled={busy || w.cycle.choices_locked}
            onChange={e => {
              setExam(e.target.files?.[0] ?? null);
              setPreview(null);
            }}
          />
        </label>
        <div className="actions">
          <button
            disabled={busy || !exam || w.cycle.choices_locked}
            onClick={() => mutate(() => examImport(false), 'Preview calculated. No results were changed.')}
          >
            Preview ranks
          </button>
          <Confirm
            label="Commit exam import"
            title="Commit these exam results?"
            disabled={busy || !preview || preview.committed || w.cycle.choices_locked}
            onConfirm={() =>
              mutate(() => examImport(true), 'Exam results imported and annual ranks recalculated.')
            }
          >
            <p>
              This imports {preview?.imported_rows} rows and reranks the {preview?.cohort_size}-student
              cohort. A changed input revision rejects the commit.
            </p>
          </Confirm>
        </div>
        {preview && (
          <>
            <p className="small muted">
              {preview.cohort_size} candidates / revision {preview.input_revision} /{' '}
              {preview.committed ? 'Committed' : 'Preview only'}
            </p>
            <Table
              rows={preview.results}
              label="Rank preview"
              columns={[
                { label: 'Student ID', render: r => r.student_id },
                { label: 'Category', render: r => r.category },
                { label: 'Total', render: r => r.total_marks },
                { label: 'Common rank', render: r => r.crl_rank },
                {
                  label: 'Category rank',
                  render: r => (r.category === 'OPEN' ? 'Not applicable' : r.cat_rank),
                },
              ]}
            />
          </>
        )}
      </section>
      <section>
        <h2>Historical cutoffs</h2>
        <p className="small muted">
          Import opening and closing ranks per year, round, program and pool. Identify synthetic data
          explicitly.
        </p>
        <a href="/samples/cutoffs.csv" download>
          Download example cutoff CSV
        </a>
        <form
          onSubmit={e => {
            e.preventDefault();
            if (!history) return;
            const data = new FormData();
            data.append('file', history);
            mutate(async () => {
              const result = await api<{ refreshed: boolean }>('/admin/history/import', {
                method: 'POST',
                body: data,
              });
              if (!result.refreshed)
                throw new Error('History imported, but bands are stale. Retry the refresh.');
            }, 'Historical cutoffs imported and prediction bands refreshed.');
          }}
        >
          <label>
            Historical CSV
            <input
              required
              type="file"
              accept=".csv,text/csv"
              onChange={e => setHistory(e.target.files?.[0] ?? null)}
            />
          </label>
          <button disabled={busy || !history}>Import cutoffs</button>
        </form>
      </section>
    </>
  );
}
