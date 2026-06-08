import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Mail, Lock, ArrowRight, Loader2, Eye, EyeOff } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';

export const LoginPage = () => {
  const { signIn } = useAuth();
  const navigate = useNavigate();

  const [form, setForm] = useState({ email: '', password: '' });
  const [showPassword, setShowPassword] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const updateForm = (field: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((prev) => ({ ...prev, [field]: e.target.value }));

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    setIsLoading(true);

    const { error: err } = await signIn(form.email, form.password);
    setIsLoading(false);

    if (err) {
      setError('Invalid email or password. Please try again.');
    } else {
      navigate('/');
    }
  };

  return (
    <div className="auth-root">
      {/* Left Panel — Branding */}
      <div className="auth-brand-panel">
        <div className="auth-brand-inner">
          <div className="auth-logo">
            Nexus<span>LPG</span>
          </div>
          <h2 className="auth-brand-headline">
            Welcome back to<br />your ERP Dashboard
          </h2>
          <p className="auth-brand-sub">
            Sign in to access your real-time inventory ledger, financial statements, and logistics management.
          </p>

          <div className="auth-brand-stat-row">
            <div className="auth-brand-stat">
              <div className="auth-brand-stat-value">∞</div>
              <div className="auth-brand-stat-label">Audit Trail</div>
            </div>
            <div className="auth-brand-stat">
              <div className="auth-brand-stat-value">0</div>
              <div className="auth-brand-stat-label">Data Loss</div>
            </div>
            <div className="auth-brand-stat">
              <div className="auth-brand-stat-value">1ms</div>
              <div className="auth-brand-stat-label">Latency</div>
            </div>
          </div>
        </div>

        <div className="auth-brand-orb auth-brand-orb-1" />
        <div className="auth-brand-orb auth-brand-orb-2" />
      </div>

      {/* Right Panel — Form */}
      <div className="auth-form-panel">
        <div className="auth-form-card glass-panel">
          <h1 className="auth-form-title">Sign in</h1>
          <p className="auth-form-subtitle">
            Enter your credentials to access your NexusLPG workspace.
          </p>

          {error && <div className="auth-error">{error}</div>}

          <form onSubmit={handleSubmit} noValidate>
            <div className="auth-fields">
              <div className="input-group">
                <label className="input-label" htmlFor="email">Email Address</label>
                <div className="input-icon-wrapper">
                  <Mail size={16} className="input-icon" />
                  <input
                    id="email"
                    type="email"
                    className="input-field input-with-icon"
                    placeholder="owner@yourbusiness.com"
                    value={form.email}
                    onChange={updateForm('email')}
                    required
                    autoFocus
                  />
                </div>
              </div>

              <div className="input-group">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <label className="input-label" htmlFor="password">Password</label>
                  <a href="#" style={{ fontSize: '0.75rem' }}>Forgot password?</a>
                </div>
                <div className="input-icon-wrapper">
                  <Lock size={16} className="input-icon" />
                  <input
                    id="password"
                    type={showPassword ? 'text' : 'password'}
                    className="input-field input-with-icon"
                    placeholder="Your password"
                    value={form.password}
                    onChange={updateForm('password')}
                    required
                  />
                  <button
                    type="button"
                    className="input-eye"
                    onClick={() => setShowPassword((v) => !v)}
                  >
                    {showPassword ? <EyeOff size={16} /> : <Eye size={16} />}
                  </button>
                </div>
              </div>

              <button
                type="submit"
                className="btn btn-primary auth-submit-btn"
                disabled={isLoading}
              >
                {isLoading ? (
                  <><Loader2 size={16} className="spin" /> Signing in…</>
                ) : (
                  <>Sign In <ArrowRight size={16} /></>
                )}
              </button>
            </div>
          </form>

          <p className="auth-footer-text">
            Don't have an account?{' '}
            <Link to="/register">Create a Business</Link>
          </p>
        </div>
      </div>
    </div>
  );
};
