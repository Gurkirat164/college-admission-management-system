import { useEffect, useState, type FormEvent } from 'react';
import { ArrowRight, BookOpen, ShieldCheck } from 'lucide-react';
import { api, errorMessage, post } from '../../lib/api';
import type { DemoAccount } from '../../lib/types';

export default function Login({ onLogin }: { onLogin: () => Promise<void> }) {
  const [email, setEmail] = useState(''),
    [password, setPassword] = useState(''),
    [name, setName] = useState('');
  const [register, setRegister] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState('');
  const [accounts, setAccounts] = useState<DemoAccount[]>([]);
  useEffect(() => {
    api<DemoAccount[]>('/dev/accounts')
      .then(setAccounts)
      .catch(() => {});
  }, []);
  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      await post(register ? '/auth/register' : '/auth/login', {
        email,
        password,
        ...(register ? { full_name: name } : {}),
      });
      await onLogin();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="login-layout">
      <section className="login-story">
        <div className="wordmark">
          <BookOpen size={25} />
          Admission desk
        </div>
        <div>
          <h1>A place for every decision.</h1>
          <p>College admissions, with a clear reason behind every allocation.</p>
          <div className="story-rule" />
          <p className="muted">
            <ShieldCheck size={18} /> Ranked choices. Fair allocation. A verifiable record.
          </p>
        </div>
        <p className="small muted">College demo. Synthetic admission records.</p>
      </section>
      <section className="login-form">
        <h2>{register ? 'Create your student account' : 'Welcome to the desk'}</h2>
        <p className="muted">
          {register
            ? 'Start with your name and sign-in details.'
            : 'Sign in to continue your admission work.'}
        </p>
        <form onSubmit={submit}>
          {register && (
            <label>
              Full name
              <input
                required
                minLength={2}
                maxLength={100}
                value={name}
                onChange={e => setName(e.target.value)}
                autoComplete="name"
              />
            </label>
          )}
          <label>
            Email address
            <input
              required
              type="email"
              value={email}
              onChange={e => setEmail(e.target.value)}
              autoComplete="username"
            />
          </label>
          <label>
            Password
            <input
              required
              type="password"
              minLength={register ? 10 : 1}
              value={password}
              onChange={e => setPassword(e.target.value)}
              autoComplete={register ? 'new-password' : 'current-password'}
            />
          </label>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <button disabled={busy} aria-busy={busy}>
            {busy ? 'Signing in…' : register ? 'Create account' : 'Sign in'}
            <ArrowRight size={17} />
          </button>
        </form>
        <button
          className="text-button"
          onClick={() => {
            setRegister(!register);
            setError('');
          }}
        >
          {register ? 'Already registered? Sign in' : 'New applicant? Create an account'}
        </button>
        {accounts.length > 0 && !register && (
          <section className="demo-access">
            <h3>Explore the local demo</h3>
            <p className="small muted">Choose a synthetic account to fill the form.</p>
            <div className="demo-buttons">
              {accounts.map(a => (
                <button
                  className="quiet"
                  key={a.email}
                  onClick={() => {
                    setEmail(a.email);
                    setPassword(a.password);
                  }}
                >
                  {a.role === 'STUDENT'
                    ? 'Student'
                    : a.role === 'ADMIN'
                      ? 'Admin'
                      : a.role === 'ANALYST'
                        ? 'Analyst'
                        : 'Auditor'}
                </button>
              ))}
            </div>
          </section>
        )}
      </section>
    </main>
  );
}
