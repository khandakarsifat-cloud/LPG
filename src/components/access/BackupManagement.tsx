import { useEffect, useRef, useState } from 'react';
import { Archive, ArrowUpRight, CalendarClock, Check, CheckCheck, Cloud, Database, Download, HardDrive, KeyRound, Link2, LockKeyhole, RefreshCw, ShieldCheck, TriangleAlert, Unplug } from 'lucide-react';
import { useBackupAction, useBackups } from '../../hooks/useBackups';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import type { BackupStatus } from '../../types/backup';
import './backups.css';

const date = (value?: string) => value ? new Date(value).toLocaleString('en-BD', { timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }) : 'Not yet available';
function bytes(value?: number | null) {
  if (value == null) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']; let index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; }
  return `${value.toLocaleString('en-BD', { maximumFractionDigits: index > 1 ? 2 : 0 })} ${units[index]}`;
}
type Dialog = 'disconnect' | 'schedule' | 'recovery' | 'queue' | 'full' | null;

function duration(seconds: number) {
  const minutes = Math.floor(seconds / 60);
  return minutes ? `${minutes}m ${Math.floor(seconds % 60)}s` : `${Math.floor(seconds)}s`;
}
function BackupProgress({ job }: { job: BackupStatus['job'] }) {
  const [clock, setClock] = useState(() => Date.now());
  useEffect(() => { const timer = window.setInterval(() => setClock(Date.now()), 1000); return () => clearInterval(timer); }, []);
  const elapsed = job.duration_seconds ?? (job.started_at ? Math.max(0, (clock - Date.parse(job.started_at)) / 1000) : 0);
  const active = job.status === 'running' || job.status === 'queued';
  return <section className="settings-card backup-progress" aria-label="Full backup progress">
    <div className="purchase-section-heading"><h2>{job.phase ?? 'Preparing'}</h2>{job.percent != null && <strong>{job.percent.toFixed(1)}%</strong>}</div>
    <p role="status" aria-live="polite">{job.detail ?? (active ? 'The backup continues on the server. You can leave this page and return.' : 'Backup verification has finished.')}</p>
    {active && job.percent == null ? <progress aria-label="Current backup stage progress" /> : <progress aria-label="Current backup stage progress" max={100} value={job.percent ?? 0} />}
    <dl className="backup-policy"><div><dt>Elapsed</dt><dd>{duration(elapsed)}</dd></div><div><dt>Processed / stage total</dt><dd>{bytes(job.processed_bytes ?? undefined)} / {bytes(job.total_bytes ?? undefined)}</dd></div><div><dt>Upload network data transferred</dt><dd>{bytes(job.network_transferred_bytes ?? undefined)}</dd></div><div><dt>Compressed new data uploaded</dt><dd>{bytes(job.transferred_bytes ?? undefined)}</dd></div><div><dt>Estimated stage time remaining</dt><dd>{job.remaining_seconds != null ? duration(job.remaining_seconds) : 'Measured when available'}</dd></div></dl>
    <p className="backup-footnote">Percentages describe measured stage progress. Database capture, compression and recovery checks remain indeterminate when their engines do not report a reliable total. Processed bytes include deduplicated data. Network traffic is sampled live; the compressed upload total is finalized after upload.</p>
  </section>;
}

export function BackupManagement() {
  const query = useBackups(); const action = useBackupAction();
  const [dialog, setDialog] = useState<Dialog>(null); const [page, setPage] = useState(0);
  const [notice, setNotice] = useState('');
  const fullRequest = useRef<string | null>(null);
  async function connect() {
    setNotice('');
    try { const result = await action.mutateAsync({ action: 'connect' }); if (result.url) window.location.assign(result.url); } catch { /* inline error */ }
  }
  async function confirm(data: BackupStatus) {
    try {
      if (dialog === 'disconnect') await action.mutateAsync({ action: 'disconnect' });
      if (dialog === 'schedule') await action.mutateAsync({ action: 'settings', body: { enabled: !data.settings.enabled } });
      if (dialog === 'queue') { await action.mutateAsync({ action: 'queue' }); setNotice('Backup requested for the next nightly window.'); }
      if (dialog === 'full') { fullRequest.current ??= crypto.randomUUID(); await action.mutateAsync({ action: 'full', body: { request_id: fullRequest.current } }); fullRequest.current = null; setNotice('Full backup started on the server. The automatic schedule is unchanged.'); }
      setDialog(null);
    } catch { /* retain confirmation and inline error */ }
  }
  if (query.isPending) return <section className="settings-card backup-loading" role="status"><Cloud size={26} /><div><h2>Loading backup health</h2><p>Checking the local backup controller…</p></div></section>;
  if (!query.data) return <section className="settings-card backup-loading" role="alert"><TriangleAlert size={26} /><div><h2>Backup status unavailable</h2><p>{query.error?.message}</p><button className="btn btn-secondary" onClick={() => void query.refetch()}>Try again</button></div></section>;
  const data = query.data; const latest = data.history.find(point => point.status === 'verified' && !point.previous_generation);
  const running = data.job.status === 'running' || data.job.status === 'queued'; const failed = ['failed', 'interrupted'].includes(data.job.status);
  const points = data.history.filter(point => point.available && !point.previous_generation).length;
  const stale = data.overdue === true;
  const healthy = !!latest && !stale && !failed && data.settings.enabled && data.connection.connected;
  const accountUsed = data.usage?.total !== undefined && data.usage.free !== undefined ? data.usage.total - data.usage.free : undefined;
  const usedPercent = data.usage?.total ? Math.min(100, (accountUsed ?? 0) / data.usage.total * 100) : 0;
  const title = running ? data.job.phase ?? 'Backup in progress' : stale ? 'Latest cloud recovery point is overdue' : failed ? 'Backup needs attention' : !data.settings.enabled ? 'Scheduled backups paused' : healthy ? 'Cloud recovery points are available' : data.connection.connected ? 'First cloud backup is scheduled' : 'Connect Google Drive to protect your data';
  return <div className="backup-workspace">
    <section className={`backup-health settings-card ${failed ? 'backup-health-error' : ''}`} aria-label="Backup health">
      <span className="backup-health-icon">{failed ? <TriangleAlert size={25} /> : <ShieldCheck size={27} />}</span>
      <div><div className="backup-eyebrow">Whole-system recovery <span>Asia/Dhaka</span></div><h2>{title}</h2><p>{running ? 'The server will finish capture, upload and verification before releasing the backup lock.' : 'All businesses, Auth, PostgreSQL, uploaded files and essential server configuration in one encrypted repository.'}</p></div>
      <button className="btn btn-secondary" disabled={query.isFetching} onClick={() => void query.refetch()}><RefreshCw size={16} aria-hidden="true" />{query.isFetching ? 'Refreshing…' : 'Refresh status'}</button>
    </section>
    {(failed || query.error) && <p className="purchase-error" role="alert">{data.job.error ?? query.error?.message}</p>}
    {action.error && !dialog && <p className="purchase-error" role="alert">{action.error.message}</p>}
    {notice && <p className="backup-notice" role="status"><Check size={17} aria-hidden="true" />{notice}</p>}
    <div className="backup-buttons"><button className="btn btn-primary" disabled={action.isPending || running || !data.connection.connected} onClick={() => { action.reset(); setDialog('full'); }}><Archive size={16} aria-hidden="true" />{running ? 'Backup in progress' : failed ? 'Retry Full Backup' : 'Create Full Backup'}</button><span>Starts immediately. Scheduled backups continue at 2:00 AM.</span></div>
    {(running || data.job.status === 'completed') && <BackupProgress job={data.job} />}
    <dl className="backup-metrics">
      <div className="settings-card"><dt><CheckCheck size={17} aria-hidden="true" />Last verified backup</dt><dd className="backup-date">{latest ? date(latest.captured_at) : 'No cloud backup yet'}</dd><small>{latest ? `${latest.type === 'full' ? 'Full' : 'Incremental'} PostgreSQL · files & configuration` : 'A point appears here only after cloud verification'}</small></div>
      <div className="settings-card"><dt><CalendarClock size={17} aria-hidden="true" />Next nightly window</dt><dd className="backup-date">{data.settings.enabled ? date(data.next_run) : 'Paused'}</dd><small>{data.queued ? 'On-demand backup queued' : '2:00 AM daily · upload continues until finished'}</small></div>
      <div className="settings-card"><dt><Archive size={17} aria-hidden="true" />Available recovery points</dt><dd>{points}<span>points</span></dd><small>30 daily days + 12 monthly full points</small></div>
      <div className="settings-card"><dt><HardDrive size={17} aria-hidden="true" />Cloud backup storage</dt><dd>{bytes(data.usage?.backup_bytes)}</dd><small>Encrypted, compressed & deduplicated</small></div>
    </dl>
    <div className="backup-columns">
      <section className="settings-card backup-drive"><header><div className="backup-section-title"><Cloud size={21} aria-hidden="true" /><h2>Google Drive</h2></div><span className={`backup-pill ${data.connection.connected ? 'backup-pill-good' : ''}`}>{data.connection.connected ? 'Connected' : 'Not connected'}</span></header>
        <strong className="backup-account">{data.connection.account ?? (data.connection.connected ? 'Account validation pending' : 'Connect your backup account')}</strong>
        <p>{data.connection.connected ? 'Authorized for unattended encrypted backups.' : 'One Google account protects the entire platform. Grant access only to files created by this backup app.'}</p>
        <div className="backup-capacity" role="meter" aria-label="Google Drive storage used" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(usedPercent)} aria-valuetext={data.usage ? `${bytes(accountUsed)} used of ${bytes(data.usage.total)}` : 'Measured in the nightly window'}><span style={{ width: `${usedPercent}%` }} /></div>
        <dl className="backup-capacity-labels"><div><dt>Total</dt><dd>{bytes(data.usage?.total)}</dd></div><div><dt>Account used</dt><dd>{bytes(accountUsed)}</dd></div><div><dt>Available</dt><dd>{bytes(data.usage?.free)}</dd></div></dl>
        <p className="backup-footnote">{data.usage ? `Measured ${date(data.usage.measured_at)}. ` : ''}Usage includes Drive and other Google services. Refreshed during nightly backups and account connection.</p>
        <div className="backup-buttons"><button className="btn btn-primary" disabled={action.isPending || !data.credentials_installed || running} onClick={() => void connect()}><Link2 size={16} aria-hidden="true" />{data.connection.connected ? 'Reconnect account' : 'Connect Google Drive'}<ArrowUpRight size={15} aria-hidden="true" /></button>{data.connection.connected && <button className="btn btn-secondary" disabled={action.isPending || running} onClick={() => { action.reset(); setDialog('disconnect'); }}><Unplug size={16} aria-hidden="true" />Disconnect</button>}</div>
        {!data.credentials_installed && <p className="purchase-error">The private Web OAuth credential needs to be installed on the VPS.</p>}
        {data.authorization_error && <p className="purchase-error" role="alert">{data.authorization_error.message}</p>}
      </section>
      <section className="settings-card backup-plan"><header><div className="backup-section-title"><CalendarClock size={21} aria-hidden="true" /><h2>Schedule & retention</h2></div><button className="backup-text-button" onClick={() => { action.reset(); setDialog('schedule'); }}>Manage</button></header>
        <dl className="backup-policy"><div><dt>Monthly full</dt><dd>1st · 2:00 AM <span>12 months</span></dd></div><div><dt>Daily incremental</dt><dd>Other nights · 2:00 AM <span>30 days</span></dd></div><div><dt>Files & configuration</dt><dd>Every night <span>With each point</span></dd></div><div><dt>Cloud verification</dt><dd>Every night <span>Restore drill monthly</span></dd></div></dl>
        <div className="backup-window-note"><LockKeyhole size={17} aria-hidden="true" /><p>Automatic backups use the nightly window. Create Full Backup starts an administrator-requested backup immediately.</p></div>
        <button className="btn btn-secondary" disabled={action.isPending || running || data.queued || !data.settings.enabled} onClick={() => { action.reset(); setDialog('queue'); }}><Archive size={16} aria-hidden="true" />{data.queued ? 'Backup queued for tonight' : 'Request backup'}</button>
      </section>
    </div>
    <section className="settings-card backup-history"><header><div><div className="backup-section-title"><Database size={21} aria-hidden="true" /><h2>Recovery point history</h2></div><p>Times in Bangladesh · every available point includes its complete restore dependencies.</p></div><span className="backup-pill">{data.history.length} recorded</span></header>
      {!data.history.length ? <div className="backup-empty"><Archive size={30} aria-hidden="true" /><h3>Your first recovery point will appear here</h3><p>Connect Drive and keep the schedule enabled. The first backup is full; later nightly backups are incremental.</p></div> : <><div className="backup-history-table"><table><thead><tr><th>Recovery point</th><th>PostgreSQL</th><th>Backup change</th><th>Cloud added</th><th>Status</th></tr></thead><tbody>{data.history.slice(page * 10, page * 10 + 10).map(point => <tr key={point.snapshot_id}><td data-label="Recovery point"><strong>{date(point.captured_at)}</strong><small>{point.previous_generation ? 'Previous data generation · isolated recovery only' : point.monthly ? 'Monthly recovery point' : 'Daily recovery point'}</small></td><td data-label="PostgreSQL"><span className="backup-pill">{point.type === 'full' ? 'Full' : 'Incremental'}</span></td><td data-label="Backup change">{bytes(point.backup_bytes)}</td><td data-label="Cloud added">{bytes(point.cloud_bytes_added)}</td><td data-label="Status"><span className={`backup-point-status ${point.available ? 'backup-pill-good' : point.status === 'failed' ? 'backup-point-failed' : ''}`}>{point.status === 'failed' ? <TriangleAlert size={15} aria-hidden="true" /> : point.status === 'uploaded' ? <RefreshCw size={15} aria-hidden="true" /> : <CheckCheck size={15} aria-hidden="true" />}{point.available ? 'Verified · available' : point.status === 'failed' ? 'Verification failed' : point.status === 'uploaded' ? 'Verification pending' : 'Expired'}</span>{point.error && <small className="purchase-error">{point.error}</small>}</td></tr>)}</tbody></table></div><div className="access-pagination"><span>{Math.min(page * 10 + 1, data.history.length)}–{Math.min((page + 1) * 10, data.history.length)} of {data.history.length}</span><button className="btn btn-secondary" disabled={page === 0} onClick={() => setPage(page - 1)}>Previous</button><button className="btn btn-secondary" disabled={(page + 1) * 10 >= data.history.length} onClick={() => setPage(page + 1)}>Next</button></div></>}
    </section>
    {!!data.jobs?.length && <section className="settings-card backup-history"><h2>Backup job history</h2><div className="backup-history-table"><table><thead><tr><th>Started / completed</th><th>Destination</th><th>Size / uploaded</th><th>Duration</th><th>Status</th></tr></thead><tbody>{data.jobs.slice(0, 20).map(job => <tr key={job.job_id}><td>{date(job.started_at)}<small>{date(job.completed_at ?? job.failed_at)}</small></td><td>{job.destination ?? 'Google Drive'}</td><td>{bytes(job.total_bytes)}<small>{bytes(job.transferred_bytes)} uploaded</small></td><td>{job.duration_seconds != null ? duration(job.duration_seconds) : '—'}</td><td>{job.status}{job.error && <small className="purchase-error">{job.error}</small>}</td></tr>)}</tbody></table></div></section>}
    <section className="settings-card backup-recovery"><div className="backup-section-title"><KeyRound size={22} aria-hidden="true" /><div><h2>Replacement VPS recovery</h2><p>{data.recovery ? `Last isolated recovery test: ${date(data.recovery.verified_at)}` : 'A complete isolated recovery test runs after the first cloud backup and monthly thereafter.'}</p></div></div><div className="backup-recovery-actions"><span className={`backup-pill ${data.key_exported ? 'backup-pill-good' : 'backup-pill-warning'}`}>{data.key_exported ? 'Recovery key copied off VPS' : 'Recovery key needs off-VPS copy'}</span><button className="btn btn-secondary" onClick={() => setDialog('recovery')}><Download size={16} aria-hidden="true" />Recovery information</button></div></section>
    {dialog && <PurchaseDialog title={dialog === 'full' ? 'Create Full Backup now?' : dialog === 'disconnect' ? 'Disconnect Google Drive?' : dialog === 'schedule' ? 'Backup schedule' : dialog === 'queue' ? 'Request a nightly backup' : 'Disaster recovery'} subtitle="Whole-system recovery · Asia/Dhaka" onClose={() => { setDialog(null); action.reset(); }} busy={action.isPending} compact>
      <div className="modal-body backup-dialog">
        {dialog === 'full' && <><p>Create a full database, uploaded-file and configuration backup now, then compress, upload and verify it in Google Drive?</p><p>The server continues if you close or refresh this page. Storage uploads and downloads briefly pause during the consistent capture. The automatic schedule is unchanged.</p></>}
        {dialog === 'disconnect' && <><p>Cloud uploads will stop. Existing encrypted backups stay in Google Drive, and the recovery key remains unchanged.</p><p>Reconnect the same Google account to continue using its recovery repository. To revoke the Google permission entirely, remove this app from your Google account’s third-party connections.</p></>}
        {dialog === 'queue' && <><p>The request will run at <strong>{date(data.next_run)}</strong>. It will capture the database, uploaded files and essential configuration, then upload and verify one recovery point.</p><p>Storage uploads and downloads briefly pause during capture. Interrupted transfers retry in the same nightly job and can continue the following night.</p></>}
        {dialog === 'schedule' && <><dl className="backup-policy"><div><dt>Timezone</dt><dd>Asia/Dhaka</dd></div><div><dt>Daily start</dt><dd>2:00 AM</dd></div><div><dt>Daily retention</dt><dd>30 days</dd></div><div><dt>Monthly retention</dt><dd>12 full points</dd></div></dl><p>These recovery requirements are fixed so changes cannot silently shorten protection. {data.settings.enabled ? 'Pausing stops scheduled captures and cloud uploads until you resume.' : 'Resume to capture and upload at the next nightly window.'}</p></>}
        {dialog === 'recovery' && <><div className="backup-window-note"><KeyRound size={20} aria-hidden="true" /><p><strong>Keep the recovery kit outside the VPS.</strong> The encryption password is deliberately excluded from cloud backups. Without it, encrypted data cannot be recovered.</p></div><ol><li>Retrieve the separately saved recovery kit and reconnect the original Google account.</li><li>On a fresh isolated VPS, download a chosen Restic recovery point and verify it.</li><li>Restore the pinned PostgreSQL cluster, Storage objects, encryption keys and saved configuration.</li><li>Verify Auth, tenant permissions and accounting before changing DNS or frontend configuration.</li></ol><p>The exact commands are in <code>deploy/backup/recovery.md</code> and the off-VPS kit. Restoration never runs against the live application from this panel.</p><p>{data.recovery?.limitation ?? 'Cloud restoration has not been verified yet.'}</p></>}
        {action.error && <p className="purchase-error" role="alert">{action.error.message}</p>}
      </div><div className="modal-footer"><button className="btn btn-secondary" disabled={action.isPending} onClick={() => { setDialog(null); action.reset(); }}>{dialog === 'recovery' ? 'Close' : 'Cancel'}</button>{dialog !== 'recovery' && <button className="btn btn-primary" disabled={action.isPending} onClick={() => void confirm(data)}>{action.isPending ? 'Saving…' : dialog === 'full' ? 'Create Full Backup' : dialog === 'disconnect' ? 'Disconnect account' : dialog === 'queue' ? 'Queue backup' : data.settings.enabled ? 'Pause schedule' : 'Resume schedule'}</button>}</div>
    </PurchaseDialog>}
  </div>;
}
