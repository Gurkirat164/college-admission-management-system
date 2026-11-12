import { useMemo, useRef, useState } from 'react';
import { categoryLabel as label, friendly, post } from '../../lib/api';
import { useData } from '../../lib/useData';
import type { OverviewData, OverviewSeat, OverviewUnplaced } from '../../lib/types';
import type { Actions } from '../../components/ui';
import Analytics from './Analytics';

const CATEGORY_ORDER = ['OPEN', 'EWS', 'OBC_NCL', 'SC', 'ST'];
const firstName = (name: string) => name.split(' ')[0];
const ordinal = (n: number) => {
  const tens = n % 100;
  if (tens >= 11 && tens <= 13) return `${n}th`;
  return `${n}${({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th'}`;
};

// Pools with more seats than this are drawn as small unlabelled blocks.
const LABELLED_SEAT_LIMIT = 8;
// A pool never draws more blocks than this; the rest is summarised as "+N".
const DRAWN_SEAT_LIMIT = 60;
// Above this many students the rank chart switches to non-interactive dots.
const INTERACTIVE_DOT_LIMIT = 400;

interface SeatSlot {
  id: string;
  holder: OverviewSeat | null;
}
interface PoolCell {
  category: string;
  seats: number;
  slots: SeatSlot[];
  hidden: number;
  held: number;
  closing: number | null;
}
interface ProgramRow {
  program_id: number;
  code: string;
  institute: string;
  cells: (PoolCell | null)[];
}
interface Detail {
  where: string;
  who: string;
  lines: string[];
  note?: string;
}

function formatWhen(value: string, withDate = true) {
  const date = new Date(value);
  const time = date.toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' });
  const today = new Date().toDateString() === date.toDateString();
  if (today || !withDate) return time;
  return `${date.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}, ${time}`;
}

/** A student in a reserved pool who got a better choice than someone with a better common rank. */
function findReservedAdvantage(seats: OverviewSeat[]) {
  const open = seats.filter(s => s.seat_category === 'OPEN' && s.crl_rank != null);
  for (const held of [...seats]
    .filter(s => s.seat_category !== 'OPEN' && s.crl_rank != null)
    .sort((a, b) => a.crl_rank! - b.crl_rank!)) {
    const passed = open
      .filter(o => o.crl_rank! < held.crl_rank! && o.pref_order > held.pref_order)
      .sort((a, b) => b.crl_rank! - a.crl_rank!)[0];
    if (passed) return { held, passed };
  }
  return null;
}

function unplacedNote(reason: string | null) {
  switch (reason) {
    case 'NO_ELIGIBLE_CHOICES':
      return 'None of the listed programs accept these marks or this category.';
    case 'ALL_ELIGIBLE_CHOICES_FULL':
      return 'Every eligible choice filled with better-ranked applicants.';
    case 'APPLICATION_NOT_VERIFIED':
      return 'The application is not verified, so it was left out of the run.';
    case 'WITHDRAWN':
      return 'Withdrew from counselling.';
    default:
      return undefined;
  }
}

export default function Overview({
  workspace: w,
  mutate,
  busy,
  navigate,
}: Actions & { navigate: (id: string) => void }) {
  const { data, error, loading, reload } = useData<OverviewData>(`/admin/overview/${w.year}`, w);
  const [selected, setSelected] = useState<string | null>(null);
  const detailRef = useRef<HTMLDivElement>(null);
  // On a phone the explanation sits below the plan, so bring it into view after a tap.
  const select = (id: string) => {
    setSelected(id);
    if (matchMedia('(max-width: 720px)').matches) {
      requestAnimationFrame(() =>
        detailRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }),
      );
    }
  };

  const model = useMemo(() => {
    if (!data) return null;
    const categories = CATEGORY_ORDER.filter(c => data.pools.some(p => p.seat_category === c));
    const programs: ProgramRow[] = [];
    for (const pool of data.pools) {
      let row = programs.find(p => p.program_id === pool.program_id);
      if (!row) {
        row = {
          program_id: pool.program_id,
          code: pool.code,
          institute: pool.institute,
          cells: categories.map(() => null),
        };
        programs.push(row);
      }
      const holders = data.seats
        .filter(s => s.program_id === pool.program_id && s.seat_category === pool.seat_category)
        .sort((a, b) => a.rank_used - b.rank_used);
      const drawn = Math.min(pool.seats, DRAWN_SEAT_LIMIT);
      const slots: SeatSlot[] = Array.from({ length: drawn }, (_, i) => ({
        id: `${pool.program_id}:${pool.seat_category}:${i}`,
        holder: holders[i] ?? null,
      }));
      row.cells[categories.indexOf(pool.seat_category)] = {
        category: pool.seat_category,
        seats: pool.seats,
        slots,
        hidden: pool.seats - drawn,
        held: holders.length,
        closing: holders.length ? holders[holders.length - 1].rank_used : null,
      };
    }
    const totalSeats = data.pools.reduce((sum, p) => sum + p.seats, 0);
    const largest = Math.max(0, ...data.pools.map(p => p.seats));
    const advantage = findReservedAdvantage(data.seats);
    return { categories, programs, totalSeats, labelled: largest <= LABELLED_SEAT_LIMIT, advantage };
  }, [data]);

  if (loading && !data)
    return (
      <header className="page-heading">
        <h1>Overview</h1>
        <p>Loading…</p>
      </header>
    );
  if (!data || !model)
    return (
      <>
        <header className="page-heading">
          <h1>Overview</h1>
        </header>
        <p role="alert" className="error">
          {error || 'The overview could not load.'} <button onClick={reload}>Try again</button>
        </p>
      </>
    );

  const { round, run } = data;
  const allSlots = model.programs.flatMap(p => p.cells.flatMap(c => c?.slots ?? []));
  const filled = data.seats.length;
  const verified = data.applicants.by_status.VERIFIED ?? 0;
  const advantage = model.advantage;
  const defaultId =
    (advantage && allSlots.find(s => s.holder?.student_id === advantage.held.student_id)?.id) ??
    allSlots.find(s => s.holder)?.id ??
    allSlots[0]?.id ??
    null;
  const selectedId = selected ?? defaultId;

  function poolCell(programId: number, category: string) {
    return model!.programs.find(p => p.program_id === programId)?.cells[model!.categories.indexOf(category)];
  }

  function describe(id: string | null): Detail | null {
    if (!id) return null;
    if (id.startsWith('u:')) {
      const person = data!.unplaced.find(u => `u:${u.student_id}` === id);
      if (!person) return null;
      return {
        where: 'Not placed',
        who: person.student_name,
        lines: person.crl_rank ? [`Common rank ${person.crl_rank}`] : [],
        note: unplacedNote(person.reason_code),
      };
    }
    const slot = allSlots.find(s => s.id === id);
    if (!slot) return null;
    const [programId, category] = id.split(':');
    const program = model!.programs.find(p => p.program_id === Number(programId))!;
    const cell = poolCell(program.program_id, category)!;
    const where = `${program.code} · ${program.institute} · ${label(category)} seat`;
    const seat = slot.holder;
    if (!seat) {
      return {
        where,
        who: 'Unfilled',
        lines: ['Nobody holds this seat in the run shown'],
        note: !run
          ? 'No allocation has run yet.'
          : data!.unplaced.length === 0
            ? 'Every applicant was placed at an earlier choice, so nobody reached this seat.'
            : `${data!.unplaced.length} unplaced ${data!.unplaced.length === 1 ? 'applicant' : 'applicants'}, but none both listed this program and qualified for this pool.`,
      };
    }
    const reserved = category !== 'OPEN';
    const lines = [
      reserved
        ? `${label(category)} rank ${seat.rank_used} · common rank ${seat.crl_rank ?? '–'}`
        : `Common rank ${seat.rank_used}`,
      `Choice ${seat.pref_order} of ${seat.choice_count}`,
      reserved
        ? `Pool closes at ${label(category)} rank ${cell.closing}`
        : `Pool closes at rank ${cell.closing}`,
    ];
    let note: string | undefined;
    if (advantage && advantage.held.student_id === seat.student_id) {
      note = `${advantage.passed.student_name} has a better common rank (${advantage.passed.crl_rank}) but got choice ${advantage.passed.pref_order}. ${firstName(seat.student_name)} reached ${program.code} through the ${label(category)} pool.`;
    } else if (!reserved && seat.admission_category !== 'OPEN') {
      const own = label(seat.admission_category);
      note = `${firstName(seat.student_name)} applied under ${own}, but common rank ${seat.crl_rank} was enough for an Open seat. That leaves the ${own} seat for the next ${own} applicant.`;
    }
    return { where, who: seat.student_name, lines, note };
  }

  const detail = describe(selectedId);

  // Rank chart: common rank across, choice received down, plus a row for anyone not placed.
  const placedPoints = data.seats.filter(s => s.crl_rank != null);
  const unplacedPoints = data.unplaced.filter(u => u.crl_rank != null);
  const maxRank = Math.max(1, ...placedPoints.map(s => s.crl_rank!), ...unplacedPoints.map(u => u.crl_rank!));
  const maxPref = Math.max(1, ...placedPoints.map(s => s.pref_order));
  const rows = [
    ...Array.from({ length: maxPref }, (_, i) => ordinal(i + 1)),
    ...(unplacedPoints.length ? ['None'] : []),
  ];
  const x = (rank: number) => (maxRank === 1 ? 50 : ((rank - 1) / (maxRank - 1)) * 100);
  const step =
    maxRank <= 15 ? 1 : [2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000].find(s => maxRank / s <= 8)!;
  const ticks = [
    ...new Set([1, ...Array.from({ length: Math.floor(maxRank / step) }, (_, i) => (i + 1) * step)]),
  ].filter(t => t <= maxRank);
  const interactive = placedPoints.length + unplacedPoints.length <= INTERACTIVE_DOT_LIMIT;
  const slotFor = (studentId: number) => allSlots.find(s => s.holder?.student_id === studentId)?.id ?? null;

  const firstChoice = placedPoints
    .filter(s => s.pref_order === 1)
    .map(s => s.crl_rank!)
    .sort((a, b) => a - b);
  const contiguous = firstChoice.length > 0 && firstChoice.every((r, i) => r === i + 1);
  const lastPlaced = [...placedPoints].sort((a, b) => b.crl_rank! - a.crl_rank!)[0];
  const chartSummary = [
    firstChoice.length
      ? contiguous && firstChoice.length > 1
        ? `Ranks 1 to ${firstChoice.length} got choice 1`
        : `${firstChoice.length} ${firstChoice.length === 1 ? 'applicant' : 'applicants'} got choice 1`
      : '',
    lastPlaced ? `rank ${lastPlaced.crl_rank} got choice ${lastPlaced.pref_order}` : '',
  ]
    .filter(Boolean)
    .join('; ');

  const runAction =
    round && (round.status === 'CHOICES_OPEN' || round.status === 'LOCKED')
      ? () =>
          mutate(
            () => post('/simulations', { round_id: round.round_id, scenario: {} }),
            'Baseline run completed.',
          )
      : null;

  return (
    <div className="overview">
      <header className="overview-title">
        <h1>{round ? `Round ${round.round_no}` : 'Overview'}</h1>
        <div className="overview-actions">
          <button className="text-button" onClick={() => navigate('rounds')}>
            Open rounds
          </button>
          {runAction && (
            <button disabled={busy} onClick={runAction}>
              Run baseline
            </button>
          )}
        </div>
      </header>

      <section className="overview-facts" aria-labelledby="round-facts">
        <div className="overview-section-head">
          <h2 id="round-facts">This round</h2>
          <span>
            {data.year} cycle{round ? ` · round ${round.round_no}` : ''}
          </span>
        </div>
        <dl className="facts">
          {round && (
            <>
              <dt>Status</dt>
              <dd>{friendly(round.status)}</dd>
            </>
          )}
          {round?.status === 'CHOICES_OPEN' && (
            <>
              <dt>Choices close</dt>
              <dd>{formatWhen(data.choice_deadline)}</dd>
            </>
          )}
          {round?.status === 'PUBLISHED' && (
            <>
              <dt>Responses due</dt>
              <dd>{formatWhen(round.response_deadline)}</dd>
            </>
          )}
          <dt>Showing</dt>
          <dd>
            {run
              ? run.is_published
                ? 'Published allocation'
                : `Baseline run #${run.sim_id} · ${run.duration_ms} ms`
              : 'No allocation yet'}
          </dd>
          {run && (
            <>
              <dt>Stability</dt>
              <dd>
                {run.checks.blocking_pairs ?? 0} blocking {run.checks.blocking_pairs === 1 ? 'pair' : 'pairs'}
              </dd>
            </>
          )}
          <dt>Seats</dt>
          <dd>
            {filled} of {model.totalSeats} filled
          </dd>
          <dt>Applicants</dt>
          <dd>
            {data.applicants.total}
            {data.applicants.total > 0 &&
              (verified === data.applicants.total
                ? ' · all verified'
                : ` · ${data.applicants.total - verified} not verified`)}
          </dd>
        </dl>

        {run?.inputs_changed && (
          <p className="overview-warning">
            Choices changed after this run. Run the baseline again for current results.
          </p>
        )}
        {data.unplaced.length > 0 && (
          <p className="overview-warning">
            {data.unplaced.length} {data.unplaced.length === 1 ? 'applicant is' : 'applicants are'} not
            placed.
          </p>
        )}
      </section>

      <section className="overview-detail" aria-labelledby="selected-seat">
        <div className="overview-section-head">
          <h2 id="selected-seat">Selected seat</h2>
          <span>From the seat plan or the rank chart</span>
        </div>
        {detail ? (
          <div className="seat-detail" aria-live="polite" ref={detailRef}>
            <span className="seat-detail-where">{detail.where}</span>
            <strong>{detail.who}</strong>
            {detail.lines.map(line => (
              <span key={line}>{line}</span>
            ))}
            {detail.note && <p>{detail.note}</p>}
          </div>
        ) : (
          <p className="muted">No seats to show.</p>
        )}
      </section>

      <section className="overview-plan" aria-labelledby="seat-plan">
        <div className="overview-section-head">
          <h2 id="seat-plan">Seat plan</h2>
          <span>{run ? 'Select a seat to see who holds it and why' : 'Run a baseline to fill the plan'}</span>
        </div>
        {model.programs.length === 0 ? (
          <p className="muted">No seats are configured for {data.year}.</p>
        ) : (
          <div className="seat-plan-scroll">
            <table className="seat-plan">
              <caption className="sr-only">Seats by program and pool</caption>
              <thead>
                <tr>
                  <th scope="col">
                    <span className="sr-only">Program</span>
                  </th>
                  {model.categories.map(c => (
                    <th scope="col" key={c}>
                      {label(c)}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {model.programs.map(program => (
                  <tr key={program.program_id}>
                    <th scope="row">
                      <b>{program.code}</b>
                      <span>{program.institute}</span>
                    </th>
                    {program.cells.map((cell, i) => (
                      <td key={model.categories[i]}>
                        {cell && (
                          <div className="pool">
                            <div className={`seats ${model.labelled ? '' : 'compact'}`}>
                              {cell.slots.map(slot => {
                                const kind = !slot.holder
                                  ? 'empty'
                                  : cell.category === 'OPEN'
                                    ? 'open'
                                    : 'reserved';
                                return (
                                  <button
                                    key={slot.id}
                                    className={`seat ${kind}`}
                                    aria-pressed={slot.id === selectedId}
                                    aria-label={`${program.code} ${program.institute}, ${label(cell.category)} seat, ${slot.holder ? slot.holder.student_name : 'unfilled'}`}
                                    onClick={() => select(slot.id)}
                                  >
                                    {model.labelled ? (slot.holder ? slot.holder.rank_used : '–') : ''}
                                  </button>
                                );
                              })}
                              {cell.hidden > 0 && <span className="seats-more">+{cell.hidden}</span>}
                            </div>
                            <span className="pool-note">
                              {cell.closing == null
                                ? `${cell.seats} open`
                                : cell.seats > cell.held
                                  ? `closes ${cell.closing} · ${cell.seats - cell.held} open`
                                  : `closes ${cell.closing}`}
                            </span>
                          </div>
                        )}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="overview-caption">
          Each block is one seat, labelled with the rank that won it: common rank for Open seats, category
          rank for reserved pools.
          {CATEGORY_ORDER.filter(c => !model.categories.includes(c)).length > 0 &&
            ` ${CATEGORY_ORDER.filter(c => !model.categories.includes(c))
              .map(label)
              .join(
                ', ',
              )} ${CATEGORY_ORDER.filter(c => !model.categories.includes(c)).length === 1 ? 'has' : 'have'} no seats this cycle.`}
        </p>
      </section>

      {run && placedPoints.length + unplacedPoints.length > 0 && (
        <section className="overview-chart" aria-labelledby="rank-chart">
          <div className="overview-section-head">
            <h2 id="rank-chart">Rank against choice received</h2>
            <span>One dot per student</span>
          </div>
          <div className="rank-chart-scroll">
            <div className="rank-chart" style={{ gridTemplateRows: `repeat(${rows.length}, 34px) 28px` }}>
              {rows.map((row, i) => (
                <span key={row} className="rank-row-label" style={{ gridRow: i + 1 }}>
                  {row}
                </span>
              ))}
              <div className="rank-plot" style={{ gridRow: `1 / span ${rows.length}` }}>
                {rows.map((row, i) => (
                  <span
                    key={row}
                    className="rank-guide"
                    style={{ top: `${((i + 0.5) / rows.length) * 100}%` }}
                  />
                ))}
                {placedPoints.map(s => {
                  const id = slotFor(s.student_id);
                  const style = {
                    left: `${x(s.crl_rank!)}%`,
                    top: `${((s.pref_order - 0.5) / rows.length) * 100}%`,
                  };
                  const kind = s.seat_category === 'OPEN' ? 'open' : 'reserved';
                  return interactive ? (
                    <button
                      key={s.student_id}
                      className={`rank-dot ${kind}`}
                      style={style}
                      aria-pressed={id === selectedId}
                      aria-label={`${s.student_name}, common rank ${s.crl_rank}, choice ${s.pref_order}`}
                      onClick={() => id && select(id)}
                    />
                  ) : (
                    <span key={s.student_id} className={`rank-dot small ${kind}`} style={style} />
                  );
                })}
                {unplacedPoints.map((u: OverviewUnplaced) => {
                  const style = {
                    left: `${x(u.crl_rank!)}%`,
                    top: `${((rows.length - 0.5) / rows.length) * 100}%`,
                  };
                  return interactive ? (
                    <button
                      key={u.student_id}
                      className="rank-dot none"
                      style={style}
                      aria-pressed={`u:${u.student_id}` === selectedId}
                      aria-label={`${u.student_name}, common rank ${u.crl_rank}, not placed`}
                      onClick={() => select(`u:${u.student_id}`)}
                    />
                  ) : (
                    <span key={u.student_id} className="rank-dot small none" style={style} />
                  );
                })}
              </div>
              <div className="rank-axis" style={{ gridRow: rows.length + 1 }}>
                {ticks.map(t => (
                  <span key={t} style={{ left: `${x(t)}%` }}>
                    {t}
                  </span>
                ))}
              </div>
            </div>
          </div>
          <p className="overview-caption">
            Common rank runs left to right; choice 1 is at the top.
            {chartSummary && ` ${chartSummary}.`}
            {advantage &&
              ` ${advantage.held.student_name}, rank ${advantage.held.crl_rank}, got choice ${advantage.held.pref_order} through the ${label(advantage.held.seat_category)} pool, while ${advantage.passed.student_name}, rank ${advantage.passed.crl_rank}, got choice ${advantage.passed.pref_order}.`}
          </p>
        </section>
      )}

      <Analytics data={data}>
        {data.recent.length > 0 && (
          <section aria-labelledby="recent">
            <div className="overview-section-head">
              <h2 id="recent">Recent activity</h2>
              <span>Allocation runs and scheduled jobs</span>
            </div>
            <ul className="recent-list">
              {data.recent.map(event => (
                <li key={`${event.kind}-${event.at}`}>
                  <time dateTime={event.at}>{formatWhen(event.at)}</time>
                  <span>
                    {event.kind === 'run'
                      ? `${event.by} ran ${event.label === 'Live baseline' ? 'baseline' : event.label.toLowerCase()} #${event.sim_id}: ${event.assigned ?? 0} of ${event.applicants ?? 0} placed${event.passed === false ? ', checks failed' : ''}`
                      : `${friendly(event.label)} ${friendly(event.status ?? '').toLowerCase()}${event.sim_id ? ` (run #${event.sim_id})` : ''}`}
                  </span>
                </li>
              ))}
            </ul>
            <button className="text-button" onClick={() => navigate('audit')}>
              Open audit log
            </button>
          </section>
        )}
      </Analytics>
    </div>
  );
}
