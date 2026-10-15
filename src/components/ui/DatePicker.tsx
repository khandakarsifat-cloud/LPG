import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import { CalendarDays, ChevronLeft, ChevronRight } from 'lucide-react';

const dateValue = (date: Date) => `${String(date.getFullYear()).padStart(4, '0')}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
const calendarDate = (year: number, month: number, day: number) => {
  const date = new Date();
  date.setHours(12, 0, 0, 0);
  date.setFullYear(year, month, day);
  return date;
};
const parseDate = (value: string) => value ? new Date(`${value}T12:00:00`) : new Date();
const months = Array.from({ length: 12 }, (_, month) => new Date(2026, month).toLocaleString('en', { month: 'long' }));

/** Keeps the native date field's typing/validation and adds a shared calendar. */
export function DatePicker({ id, label, value, onChange, min, max, required = false, disabled = false }: {
  id?: string; label: string; value: string; onChange: (value: string) => void;
  min?: string; max?: string; required?: boolean; disabled?: boolean;
}) {
  const generatedId = useId();
  const calendarId = `${generatedId}-calendar`;
  const [open, setOpen] = useState(false);
  const [cursor, setCursor] = useState(() => dateValue(parseDate(value)));
  const anchor = useRef<HTMLDivElement>(null);
  const calendar = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const active = parseDate(cursor);
  const year = active.getFullYear();
  const month = active.getMonth();
  const today = dateValue(new Date());
  const allowed = (date: string) => (!min || date >= min) && (!max || date <= max);

  useEffect(() => {
    if (!open) return;
    const panel = calendar.current;
    const position = () => {
      if (!panel || !anchor.current) return;
      const rect = anchor.current.getBoundingClientRect();
      panel.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - panel.offsetWidth - 8))}px`;
      panel.style.top = `${rect.bottom + panel.offsetHeight + 8 <= window.innerHeight ? rect.bottom + 6 : Math.max(8, rect.top - panel.offsetHeight - 6)}px`;
    };
    panel?.showPopover();
    position();
    panel?.querySelector<HTMLButtonElement>('[tabindex="0"]')?.focus();
    window.addEventListener('resize', position);
    window.addEventListener('scroll', position, true);
    return () => {
      panel?.hidePopover();
      window.removeEventListener('resize', position);
      window.removeEventListener('scroll', position, true);
    };
  }, [open]);

  const close = () => { setOpen(false); trigger.current?.focus(); };
  const choose = (date: string) => { onChange(date); close(); };
  const move = (date: Date) => {
    if (date.getFullYear() < 1 || date.getFullYear() > 9999) return;
    const next = dateValue(date);
    setCursor(next);
    requestAnimationFrame(() => calendar.current?.querySelector<HTMLButtonElement>(`[data-date="${next}"]`)?.focus());
  };
  const navigate = (event: KeyboardEvent<HTMLButtonElement>, day: Date) => {
    const next = new Date(day);
    const shifts: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7, Home: -day.getDay(), End: 6 - day.getDay() };
    if (event.key in shifts) next.setDate(next.getDate() + shifts[event.key]);
    else if (event.key === 'PageUp' || event.key === 'PageDown') {
      next.setDate(1);
      next.setMonth(next.getMonth() + (event.key === 'PageUp' ? -1 : 1));
      next.setDate(Math.min(day.getDate(), calendarDate(next.getFullYear(), next.getMonth() + 1, 0).getDate()));
    }
    else return;
    event.preventDefault();
    move(next);
  };
  const first = calendarDate(year, month, 1);
  const days = Array.from({ length: 42 }, (_, index) => calendarDate(year, month, 1 - first.getDay() + index));

  return <div className="date-field" ref={anchor}>
    <input id={id ?? generatedId} className="input-field" type="date" aria-label={label} value={value}
      min={min} max={max} required={required} disabled={disabled} onChange={event => onChange(event.target.value)}
      onKeyDown={event => { if (event.altKey && event.key === 'ArrowDown') { event.preventDefault(); setCursor(value || today); setOpen(true); } }} />
    <button ref={trigger} type="button" className="date-trigger" aria-label={`Choose date: ${label}`} aria-haspopup="dialog"
      aria-expanded={open} aria-controls={calendarId} disabled={disabled} onClick={() => { setCursor(value || today); setOpen(!open); }}><CalendarDays size={17} /></button>
    <div ref={calendar} id={calendarId} popover="auto" className="date-calendar" role="dialog" aria-label={`Choose date: ${label}`}
      onToggle={event => { if (event.newState === 'closed') setOpen(false); }} onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(); } }}>
      <div className="date-calendar-heading">
        <button type="button" aria-label="Previous month" onClick={() => move(calendarDate(year, month - 1, 1))}><ChevronLeft size={18} /></button>
        <div className="date-calendar-period">
          <select aria-label="Calendar month" value={month} onChange={event => setCursor(dateValue(calendarDate(year, Number(event.target.value), 1)))}>{months.map((name, index) => <option key={name} value={index}>{name}</option>)}</select>
          <input aria-label="Calendar year" type="number" min="1" max="9999" value={year} onChange={event => { const next = Number(event.target.value); if (next > 0 && next <= 9999) setCursor(dateValue(calendarDate(next, month, 1))); }} />
        </div>
        <button type="button" aria-label="Next month" onClick={() => move(calendarDate(year, month + 1, 1))}><ChevronRight size={18} /></button>
      </div>
      <div role="grid" aria-label={`${months[month]} ${year}`}>
        <div className="date-week" role="row">{['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'].map(day => <span key={day} role="columnheader">{day}</span>)}</div>
        {Array.from({ length: 6 }, (_, week) => <div className="date-week" role="row" key={week}>{days.slice(week * 7, week * 7 + 7).map(day => {
          const date = dateValue(day);
          return <div role="gridcell" aria-selected={date === value} key={date}><button type="button" data-date={date}
            className={`${day.getMonth() !== month ? 'outside-month ' : ''}${date === value ? 'selected ' : ''}${date === today ? 'today' : ''}`}
            aria-label={day.toLocaleDateString('en', { dateStyle: 'full' })} aria-current={date === today ? 'date' : undefined}
            aria-disabled={!allowed(date)} tabIndex={date === cursor ? 0 : -1}
            onKeyDown={event => navigate(event, day)} onClick={() => { if (allowed(date)) choose(date); }}>{day.getDate()}</button></div>;
        })}</div>)}
      </div>
      <div className="date-calendar-footer"><button type="button" disabled={!allowed(today)} onClick={() => choose(today)}>Today</button><button type="button" onClick={() => choose('')}>Clear</button></div>
    </div>
  </div>;
}
