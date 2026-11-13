import { useCallback, useEffect, useState } from 'react';
import { RefreshCw } from 'lucide-react';
import { api, errorMessage, post } from '../lib/api';
import type { Role, Workspace } from '../lib/types';
import Login from '../features/auth/Login';
import Choices from '../features/choices/Choices';
import Rounds from '../features/admin/Rounds';
import Sandbox from '../features/sandbox/Sandbox';
import Allotments from '../features/allotments/Allotments';
import Predictor from '../features/predictor/Predictor';
import Documents from '../features/applications/Documents';
import Applications from '../features/admin/Applications';
import Audit from '../features/audit/Audit';
import Spot from '../features/spot/Spot';
import Admissions from '../features/admin/Admissions';
import Operations from '../features/admin/Operations';
import Imports from '../features/admin/Imports';
import Overview from '../features/overview/Overview';
import ThemeSwitch from '../components/ThemeSwitch';

// Short labels: the top navigation has to fit on one line at laptop width.
const navigation = [
  { id: 'overview', name: 'Overview', roles: ['ADMIN'] },
  { id: 'choices', name: 'Choices', roles: ['STUDENT'] },
  { id: 'application', name: 'Application', roles: ['STUDENT'] },
  { id: 'results', name: 'Allocation', roles: ['STUDENT'] },
  { id: 'chances', name: 'Chances', roles: ['STUDENT'] },
  { id: 'rounds', name: 'Rounds', roles: ['ADMIN'] },
  { id: 'applications', name: 'Applications', roles: ['ADMIN'] },
  { id: 'admissions', name: 'Admissions', roles: ['ADMIN'] },
  { id: 'imports', name: 'Imports', roles: ['ADMIN'] },
  { id: 'operations', name: 'Jobs', roles: ['ADMIN'] },
  { id: 'sandbox', name: 'Sandbox', roles: ['ADMIN', 'ANALYST'] },
  { id: 'spot', name: 'Spot round', roles: ['ADMIN', 'STUDENT'] },
  { id: 'audit', name: 'Audit', roles: ['ADMIN', 'AUDITOR'] },
];
export default function App() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null),
    [loading, setLoading] = useState(true),
    [needsLogin, setNeedsLogin] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(''),
    [message, setMessage] = useState('');
  const [view, setView] = useState(new URLSearchParams(location.search).get('view') ?? '');
  const load = useCallback(async () => {
    try {
      const w = await api<Workspace>('/workspace');
      setWorkspace(w);
      setNeedsLogin(false);
      setError('');
    } catch (e) {
      if ((e as { status?: number }).status === 401) {
        setNeedsLogin(true);
        setWorkspace(null);
      } else setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    load();
    const update = () => setView(new URLSearchParams(location.search).get('view') ?? '');
    addEventListener('popstate', update);
    return () => removeEventListener('popstate', update);
  }, [load]);
  const mutate = async (action: () => Promise<unknown>, success: string) => {
    setBusy(true);
    setError('');
    setMessage('');
    try {
      await action();
      await load();
      setMessage(success);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  if (loading)
    return (
      <main className="startup" role="status">
        <h1>Opening the admission desk…</h1>
      </main>
    );
  if (needsLogin) return <Login onLogin={load} />;
  if (!workspace)
    return (
      <main className="startup">
        <h1>The admission desk is starting.</h1>
        <p className="error" role="alert">
          {error}
        </p>
        <button onClick={load}>
          <RefreshCw size={16} />
          Try again
        </button>
      </main>
    );
  const w = workspace,
    allowed = navigation.filter(n => n.roles.includes(w.user.role)),
    current = allowed.find(n => n.id === view) ?? allowed[0];
  const actions = { workspace: w, mutate, busy };
  function navigate(id: string) {
    history.pushState(null, '', `?view=${id}`);
    setView(id);
    setError('');
    setMessage('');
  }
  const roleName = (role: Role) =>
    ({ ADMIN: 'Admin', STUDENT: 'Student', ANALYST: 'Analyst', AUDITOR: 'Auditor' })[role];
  const page =
    current.id === 'overview' ? (
      <Overview {...actions} navigate={navigate} />
    ) : current.id === 'choices' ? (
      <Choices {...actions} />
    ) : current.id === 'rounds' ? (
      <Rounds {...actions} />
    ) : current.id === 'sandbox' ? (
      <Sandbox {...actions} />
    ) : current.id === 'results' ? (
      <Allotments {...actions} />
    ) : current.id === 'chances' ? (
      <Predictor {...actions} />
    ) : current.id === 'application' ? (
      <Documents {...actions} />
    ) : current.id === 'applications' ? (
      <Applications {...actions} />
    ) : current.id === 'spot' ? (
      <Spot {...actions} />
    ) : current.id === 'admissions' ? (
      <Admissions {...actions} />
    ) : current.id === 'imports' ? (
      <Imports {...actions} />
    ) : current.id === 'operations' ? (
      <Operations {...actions} />
    ) : (
      <Audit {...actions} />
    );
  return (
    <div className="app-shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <header className="site-header">
        <div className="header-inner">
          <a href="/" className="wordmark">
            Admission desk
          </a>
          <nav className="primary-nav" aria-label="Sections">
            {allowed.map(item => (
              <button
                className={`nav-item ${current.id === item.id ? 'selected' : ''}`}
                aria-current={current.id === item.id ? 'page' : undefined}
                key={item.id}
                onClick={() => navigate(item.id)}
              >
                {item.name}
              </button>
            ))}
          </nav>
          <div className="header-tools">
            <span className="muted header-context">
              {w.year} · {roleName(w.user.role)}
            </span>
            <ThemeSwitch />
            <button
              className="text-button"
              disabled={busy}
              onClick={() =>
                mutate(async () => {
                  await post('/auth/logout');
                  setNeedsLogin(true);
                  setWorkspace(null);
                }, '')
              }
            >
              Sign out
            </button>
          </div>
        </div>
      </header>
      <main id="main" className="workspace" aria-busy={busy}>
        {error && (
          <div className="feedback error" role="alert">
            {error}
          </div>
        )}
        {message && (
          <div className="feedback success" role="status">
            {message}
          </div>
        )}
        {page}
      </main>
      <footer className="app-footer">{w.user.full_name} · College demo, synthetic records</footer>
    </div>
  );
}
