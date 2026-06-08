import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Building2, User, Mail, Lock, ArrowRight, Loader2, Eye, EyeOff, CheckCircle2 } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';

export const RegisterPage = () => {
  const { createBusiness } = useAuth();
  const navigate = useNavigate();

  const [form, setForm] = useState({
    businessName: '',
    ownerName: '',
    email: '',
    password: '',
    confirmPassword: '',
  });
  const [showPassword, setShowPassword] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [step, setStep] = useState<1 | 2>(1);

  const updateForm = (field: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((prev) => ({ ...prev, [field]: e.target.value }));

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);

    if (form.password !== form.confirmPassword) {
      setError('Passwords do not match.');
      return;
    }
    if (form.password.length < 8) {
      setError('Password must be at least 8 characters.');
      return;
    }

    setIsLoading(true);
    const { error: err } = await createBusiness({
      businessName: form.businessName,
      ownerName: form.ownerName,
      email: form.email,
      password: form.password,
    });
    setIsLoading(false);

    if (err) {
      setError(err.message ?? 'Something went wrong. Please try again.');
    } else {
      navigate('/');
    }
  };

  const passwordStrength = (() => {
    const p = form.password;
    if (!p) return 0;
    let score = 0;
    if (p.length >= 8) score++;
    if (/[A-Z]/.test(p)) score++;
    if (/[0-9]/.test(p)) score++;
    if (/[^A-Za-z0-9]/.test(p)) score++;
    return score;
  })();

  const strengthColor = ['transparent', '#ef4444', '#f59e0b', '#3b82f6', '#10b981'][passwordStrength];
  const strengthLabel = ['', 'Weak', 'Fair', 'Good', 'Strong'][passwordStrength];

  return (
    <div className="auth-root">
      {/* Left Panel — Branding */}
      <div className="auth-brand-panel">
        <div className="auth-brand-inner">
          <div className="auth-logo">
            Nexus<span>LPG</span>
          </div>
          <h2 className="auth-brand-headline">
            Enterprise ERP for<br />LPG Distributors
          </h2>
          <p className="auth-brand-sub">
            Event-sourced inventory, immutable financial ledgers, and real-time multi-tenant operations — all in one platform.
          </p>

          <div className="auth-features">
            {[
              'Event-sourced inventory ledger',
              'Double-entry financial accounting',
              'Dynamic RBAC & audit trails',
              'Multi-tenant isolation by design',
            ].map((f) => (
              <div key={f} className="auth-feature-item">
                <CheckCircle2 size={16} />
                <span>{f}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="auth-brand-orb auth-brand-orb-1" />
        <div className="auth-brand-orb auth-brand-orb-2" />
      </div>

      {/* Right Panel — Form */}
      <div className="auth-form-panel">
        <div className="auth-form-card glass-panel">
          {/* Step Indicator */}
          <div className="auth-steps">
            <div className={`auth-step ${step >= 1 ? 'auth-step-active' : ''}`}>
              <span>1</span>
              <div className="auth-step-label">Business</div>
            </div>
            <div className="auth-step-connector" />
            <div className={`auth-step ${step >= 2 ? 'auth-step-active' : ''}`}>
              <span>2</span>
              <div className="auth-step-label">Account</div>
            </div>
          </div>

          <h1 className="auth-form-title">
            {step === 1 ? 'Create your Business' : 'Set up your Account'}
          </h1>
          <p className="auth-form-subtitle">
            {step === 1
              ? 'This creates your tenant workspace and owner account.'
              : 'Your secure login credentials for NexusLPG.'}
          </p>

          {error && (
            <div className="auth-error">
              {error}
            </div>
          )}

          <form onSubmit={handleSubmit} noValidate>
            {step === 1 && (
              <div className="auth-fields">
                <div className="input-group">
                  <label className="input-label">Business Name</label>
                  <div className="input-icon-wrapper">
                    <Building2 size={16} className="input-icon" />
                    <input
                      id="business-name"
                      type="text"
                      className="input-field input-with-icon"
                      placeholder="e.g. Acme Gas Distributors"
                      value={form.businessName}
                      onChange={updateForm('businessName')}
                      required
                      autoFocus
                    />
                  </div>
                </div>

                <div className="input-group">
                  <label className="input-label">Owner Full Name</label>
                  <div className="input-icon-wrapper">
                    <User size={16} className="input-icon" />
                    <input
                      id="owner-name"
                      type="text"
                      className="input-field input-with-icon"
                      placeholder="e.g. John Doe"
                      value={form.ownerName}
                      onChange={updateForm('ownerName')}
                      required
                    />
                  </div>
                </div>

                <button
                  type="button"
                  className="btn btn-primary auth-submit-btn"
                  onClick={() => {
                    if (form.businessName.trim() && form.ownerName.trim()) setStep(2);
                    else setError('Please fill in all fields.');
                  }}
                >
                  Continue <ArrowRight size={16} />
                </button>
              </div>
            )}

            {step === 2 && (
              <div className="auth-fields">
                <div className="input-group">
                  <label className="input-label">Email Address</label>
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
                  <label className="input-label">Password</label>
                  <div className="input-icon-wrapper">
                    <Lock size={16} className="input-icon" />
                    <input
                      id="password"
                      type={showPassword ? 'text' : 'password'}
                      className="input-field input-with-icon"
                      placeholder="Min. 8 characters"
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
                  {form.password && (
                    <div className="password-strength">
                      <div className="password-strength-bar">
                        {[1, 2, 3, 4].map((i) => (
                          <div
                            key={i}
                            className="password-strength-segment"
                            style={{ background: i <= passwordStrength ? strengthColor : 'var(--bg-elevated)' }}
                          />
                        ))}
                      </div>
                      <span style={{ color: strengthColor, fontSize: '0.75rem' }}>{strengthLabel}</span>
                    </div>
                  )}
                </div>

                <div className="input-group">
                  <label className="input-label">Confirm Password</label>
                  <div className="input-icon-wrapper">
                    <Lock size={16} className="input-icon" />
                    <input
                      id="confirm-password"
                      type={showPassword ? 'text' : 'password'}
                      className="input-field input-with-icon"
                      placeholder="Repeat your password"
                      value={form.confirmPassword}
                      onChange={updateForm('confirmPassword')}
                      required
                    />
                  </div>
                </div>

                <div className="auth-step2-actions">
                  <button
                    type="button"
                    className="btn btn-ghost"
                    onClick={() => { setStep(1); setError(null); }}
                  >
                    Back
                  </button>
                  <button
                    type="submit"
                    className="btn btn-primary auth-submit-btn"
                    disabled={isLoading}
                  >
                    {isLoading ? (
                      <><Loader2 size={16} className="spin" /> Creating Business…</>
                    ) : (
                      <>Launch NexusLPG <ArrowRight size={16} /></>
                    )}
                  </button>
                </div>
              </div>
            )}
          </form>

          <p className="auth-footer-text">
            Already have an account?{' '}
            <Link to="/login">Sign in here</Link>
          </p>
        </div>
      </div>
    </div>
  );
};
