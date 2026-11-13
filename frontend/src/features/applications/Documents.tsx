import { useRef, type FormEvent } from 'react';
import { api, post } from '../../lib/api';
import { Status, Table, type Actions } from '../../components/ui';
export default function Documents({ workspace: w, busy, mutate }: Actions) {
  const form = useRef<HTMLFormElement>(null);
  function upload(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    mutate(async () => {
      await api(`/me/applications/${w.year}/documents`, { method: 'POST', body: data });
      form.current?.reset();
    }, 'Your document was submitted for review.');
  }
  return (
    <>
      <header className="page-heading">
        <h1>Application</h1>
      </header>
      <section className="application-summary">
        <h2>{w.user.full_name}</h2>
        <p>{w.user.email}</p>
        <Status value={w.application?.status ?? 'DRAFT'} />
        {w.application?.review_reason && <p>{w.application.review_reason}</p>}
      </section>
      <form ref={form} className="upload-form" onSubmit={upload}>
        <label>
          Exam document
          <input
            required
            name="file"
            type="file"
            accept=".pdf,.png,.jpg,.jpeg"
            disabled={busy || w.cycle.choices_locked}
          />
          <span className="small muted">
            PDF, PNG or JPEG. Maximum 5 MB. Use synthetic documents locally.
          </span>
        </label>
        <button disabled={busy || w.cycle.choices_locked}>{busy ? 'Uploading…' : 'Upload document'}</button>
      </form>
      <Table
        rows={w.documents ?? []}
        label="Submitted documents"
        columns={[
          {
            label: 'Document',
            render: d => <a href={`/api/v1/documents/${d.document_id}`}>{d.original_name}</a>,
          },
          { label: 'Review', render: d => <Status value={d.status} /> },
          { label: 'Reason', render: d => d.reason ?? 'No review note' },
        ]}
      />
      {['DRAFT', 'REJECTED'].includes(w.application?.status ?? '') && (
        <button
          disabled={busy || w.cycle.choices_locked}
          onClick={() =>
            mutate(() => post(`/me/applications/${w.year}/submit`), 'Your application was submitted.')
          }
        >
          Submit application
        </button>
      )}
    </>
  );
}
