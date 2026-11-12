"""Generate docs/er-diagram.md from the migrated schema, so the diagram always matches the real tables.

Run with: npm run docs:er   (uses MIGRATION_DATABASE_URL from backend/.env)
"""
import psycopg

from app.core.config import ROOT, settings

# Diagrams are split by area so each one stays readable. Tables referenced from another area are
# drawn by name only.
GROUPS = [
    ('Identity and applications', 'Who applies, how they sign in, and what they submit for each annual cycle.',
     ['student', 'app_user', 'app_session', 'login_attempt', 'admission_cycle', 'application', 'exam_result',
      'document_submission']),
    ('Programs, seats and choices', 'What can be chosen, how many seats each pool has, and each ranked choice.',
     ['program', 'program_eligibility', 'seat_matrix', 'choice', 'hist_closing', 'prediction_state']),
    ('Rounds and outcomes', 'Published rounds, student responses, the seat each student holds, and the spot round.',
     ['counselling_round', 'allocation', 'student_response', 'seat_holding', 'final_admission', 'spot_pool',
      'spot_acceptance']),
    ('Simulation and replay', 'Immutable input snapshots, every allocation run, its results and explanations.',
     ['sim_input_snapshot', 'sim_run', 'sim_result', 'sim_student_outcome', 'sim_trace', 'sim_diff', 'job_run']),
    ('Audit and history', 'The hash-chained event ledger and the system-time history of seat capacity.',
     ['audit_ledger', 'audit_chain_head', 'seat_matrix_history']),
]

COLUMNS = """
SELECT c.table_name, c.column_name,
       CASE WHEN c.data_type = 'USER-DEFINED' THEN c.udt_name ELSE replace(c.data_type, ' ', '_') END,
       c.is_nullable = 'YES'
FROM information_schema.columns c
JOIN information_schema.tables t USING (table_schema, table_name)
WHERE c.table_schema = 'admission' AND t.table_type = 'BASE TABLE'
ORDER BY c.table_name, c.ordinal_position
"""

# Every primary key, unique and foreign key constraint with its column list.
CONSTRAINTS = """
SELECT rel.relname, con.contype,
       array(SELECT a.attname FROM unnest(con.conkey) k JOIN pg_attribute a
             ON a.attrelid = con.conrelid AND a.attnum = k ORDER BY array_position(con.conkey, k)),
       ref.relname
FROM pg_constraint con
JOIN pg_class rel ON rel.oid = con.conrelid
JOIN pg_namespace n ON n.oid = rel.relnamespace
LEFT JOIN pg_class ref ON ref.oid = con.confrelid
WHERE n.nspname = 'admission' AND con.contype IN ('p', 'u', 'f')
ORDER BY rel.relname, con.conname
"""


def short_type(name):
    return {'timestamp_with_time_zone': 'timestamptz', 'character_varying': 'varchar',
            'double_precision': 'float8'}.get(name, name)


def generate(conn):
    columns = {}
    for table, column, datatype, nullable in conn.execute(COLUMNS).fetchall():
        columns.setdefault(table, []).append((column, short_type(datatype), nullable))
    primary, unique, foreign = {}, {}, []
    for table, kind, cols, ref in conn.execute(CONSTRAINTS).fetchall():
        if kind == 'p':
            primary[table] = list(cols)
        elif kind == 'u':
            unique.setdefault(table, []).append(list(cols))
        else:
            foreign.append((table, list(cols), ref))

    grouped = {t for _, _, tables in GROUPS for t in tables}
    missing = sorted(set(columns) - grouped)
    groups = GROUPS + ([('Other tables', 'Tables not yet assigned to an area.', missing)] if missing else [])

    lines = [
        '# Entity relationships',
        '',
        'Generated from the migrated schema by `npm run docs:er` (`backend/app/er_diagram.py`). '
        'Do not edit by hand; change a migration and regenerate.',
        '',
        f'The `admission` schema has {len(columns)} tables. Each diagram covers one area; a table from another '
        'area appears by name only. Each relationship is drawn in the area of the table holding the foreign key. `PK` marks primary-key columns, `FK` foreign-key columns and `UK` columns '
        'in a unique constraint.',
        '',
        'Relationship notation: `||--o{` one to many, `||--o|` one to zero-or-one. A composite key such as '
        '`(student_id, year)` gives one row per student per admission cycle.',
    ]
    for title, description, tables in groups:
        tables = [t for t in tables if t in columns]
        lines += ['', f'## {title}', '', description, '', '```mermaid', 'erDiagram']
        shown = set(tables)
        for table, cols, ref in foreign:
            # Each relationship is drawn once, in the area of the table holding the foreign key.
            if table in shown:
                one_to_one = set(cols) == set(primary.get(table, [])) or any(
                    set(cols) == set(u) for u in unique.get(table, []))
                optional = all(nullable for c, _, nullable in columns[table] if c in cols)
                left = '|o' if optional else '||'
                right = 'o|' if one_to_one else 'o{'
                lines.append(f'    {ref} {left}--{right} {table} : "{", ".join(cols)}"')
        for table in tables:
            keys = set(primary.get(table, []))
            fks = {c for t, cols, _ in foreign if t == table for c in cols}
            uks = {c for cols in unique.get(table, []) for c in cols}
            lines.append(f'    {table} {{')
            for column, datatype, _ in columns[table]:
                marks = [m for m, on in (('PK', column in keys), ('FK', column in fks), ('UK', column in uks)) if on]
                lines.append(f'        {datatype} {column}{" " + ",".join(marks) if marks else ""}')
            lines.append('    }')
        lines.append('```')
    (ROOT / 'docs/er-diagram.md').write_text('\n'.join(lines) + '\n')
    return len(columns)


if __name__ == '__main__':
    with psycopg.connect(settings.migration_database_url) as connection:
        print(f'Wrote docs/er-diagram.md for {generate(connection)} tables.')
