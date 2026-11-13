import ThemeSwitch from '../../components/ThemeSwitch';
import { useEffect, useState, type FormEvent } from 'react';
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
      <div className="login-top">
        <span className="wordmark">Admission desk</span>
        <ThemeSwitch />
      </div>
      <section className="login-form">
        <h1>{register ? 'Create a student account' : 'Sign in'}</h1>
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
            <h2>Demo accounts</h2>
            <p className="small muted">Fills the form with a synthetic account.</p>
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
      <p className="login-footnote">College demo · synthetic admission records</p>
    </main>
  );
}
