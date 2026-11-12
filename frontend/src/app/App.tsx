import { useCallback, useEffect, useState } from 'react';
import {
  BookOpen,
  ClipboardList,
  FlaskConical,
  GraduationCap,
  History,
  Layers,
  LogOut,
  PanelLeftClose,
  RefreshCw,
  ShieldCheck,
  Sparkles,
  Users,
  FileText,
} from 'lucide-react';
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

const navigation = [
  { id: 'choices', name: 'Your choices', icon: ClipboardList, roles: ['STUDENT'] },
  { id: 'application', name: 'Application', icon: FileText, roles: ['STUDENT'] },
  { id: 'results', name: 'Allocation & reasons', icon: GraduationCap, roles: ['STUDENT'] },
  { id: 'chances', name: 'Your chances', icon: Sparkles, roles: ['STUDENT'] },
  { id: 'rounds', name: 'Counselling rounds', icon: Layers, roles: ['ADMIN'] },
  { id: 'applications', name: 'Applications', icon: Users, roles: ['ADMIN'] },
  { id: 'admissions', name: 'Final admissions', icon: GraduationCap, roles: ['ADMIN'] },
  { id: 'imports', name: 'Data imports', icon: FileText, roles: ['ADMIN'] },
  { id: 'operations', name: 'Jobs & predictions', icon: ShieldCheck, roles: ['ADMIN'] },
  { id: 'sandbox', name: 'What-if sandbox', icon: FlaskConical, roles: ['ADMIN', 'ANALYST'] },
  { id: 'spot', name: 'Spot allocation', icon: GraduationCap, roles: ['ADMIN', 'STUDENT'] },
  { id: 'audit', name: 'Audit & history', icon: History, roles: ['ADMIN', 'AUDITOR'] },
];
export default function App() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null),
    [loading, setLoading] = useState(true),
    [needsLogin, setNeedsLogin] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(''),
    [message, setMessage] = useState(''),
    [collapsed, setCollapsed] = useState(false);
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
        <BookOpen size={32} />
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
    ({
      ADMIN: 'Admission admin',
      STUDENT: 'Student',
      ANALYST: 'Sandbox analyst',
      AUDITOR: 'Read-only auditor',
    })[role];
  return (
    <div className={`app-shell ${collapsed ? 'compact-nav' : ''}`}>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <aside className="sidebar">
        <a href="/" className="wordmark">
          <BookOpen size={24} />
          <span>Admission desk</span>
        </a>
        <div className="cycle-label">
          <span>{w.year} admission cycle</span>
          <small>Synthetic demo dataset</small>
        </div>
        <nav aria-label="Main navigation">
          {allowed.map(item => (
            <button
              className={`nav-item ${current.id === item.id ? 'selected' : ''}`}
              aria-current={current.id === item.id ? 'page' : undefined}
              key={item.id}
              onClick={() => navigate(item.id)}
            >
              <item.icon size={19} />
              <span>{item.name}</span>
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="local-tag">
            <ShieldCheck size={17} />
            <span>College demo</span>
          </div>
          <p>Every result has a record.</p>
        </div>
      </aside>
      <div className="main-area">
        <header className="topbar">
          <div className="topbar-location">
            <button
              className="quiet icon-button menu-button"
              aria-label="Toggle navigation"
              onClick={() => setCollapsed(!collapsed)}
            >
              <PanelLeftClose size={18} />
            </button>
            <span>{roleName(w.user.role)}</span>
            <span className="topbar-separator">/</span>
            <strong>{current.name}</strong>
          </div>
          <div className="user-menu">
            <span>{w.user.full_name}</span>
            <button
              className="quiet icon-button"
              aria-label="Sign out"
              disabled={busy}
              onClick={() =>
                mutate(async () => {
                  await post('/auth/logout');
                  setNeedsLogin(true);
                  setWorkspace(null);
                }, '')
              }
            >
              <LogOut size={17} />
            </button>
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
          {current.id === 'choices' ? (
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
          )}
        </main>
        <footer className="app-footer">
          College Admission Management System <span>College demo / synthetic records</span>
        </footer>
      </div>
    </div>
  );
}
