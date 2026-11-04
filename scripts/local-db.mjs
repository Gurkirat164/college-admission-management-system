import {spawnSync} from 'node:child_process';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {root} from './python.mjs';

export const stateDir = path.join(root, '.local');
export function localConfig() {
  const file = path.join(stateDir, 'local.json');
  if (!existsSync(file)) throw Error('Run npm run setup first.');
  return JSON.parse(readFileSync(file, 'utf8'));
}
function run(binary, args) {
  const result = spawnSync(binary, args, {cwd: root, encoding: 'utf8', windowsHide: true});
  if (result.status !== 0) throw Error((result.stdout || '') + (result.stderr || ''));
  return result.stdout;
}
export function initializePostgres() {
  mkdirSync(stateDir, {recursive: true});
  const configPath = path.join(stateDir, 'local.json');
  if (existsSync(configPath)) return localConfig();
  const candidates = [process.env.PG_BIN, 'C:/Program Files/PostgreSQL/16/bin', 'C:/Program Files/PostgreSQL/18/bin'];
  const pgBin = candidates.find(p => p && existsSync(path.join(p, process.platform === 'win32' ? 'initdb.exe' : 'initdb')));
  if (!pgBin) throw Error('PostgreSQL binaries not found. Set PG_BIN, or use compose.yaml with PostgreSQL 16.');
  const config = {pgBin, port: 55432, ownerPassword: randomBytes(24).toString('hex'), appPassword: randomBytes(24).toString('hex')};
  const passwordFile = path.join(stateDir, 'init-password');
  writeFileSync(passwordFile, config.ownerPassword, {mode: 0o600});
  const dataDir = path.join(stateDir, 'pgdata');
  run(path.join(pgBin, 'initdb'), ['-D', dataDir, '-U', 'admission_owner', '--pwfile', passwordFile, '--auth=scram-sha-256', '--encoding=UTF8', '--locale=C']);
  writeFileSync(path.join(dataDir, 'postgresql.auto.conf'), "listen_addresses = '127.0.0.1'\nport = 55432\nmax_connections = 40\n");
  writeFileSync(configPath, JSON.stringify(config), {mode: 0o600});
  return config;
}
export function startPostgres() {
  const config = localConfig();
  const dataDir = path.join(stateDir, 'pgdata');
  const ready = spawnSync(path.join(config.pgBin, 'pg_isready'), ['-h', '127.0.0.1', '-p', String(config.port), '-U', 'admission_owner', '-d', 'admission'], {stdio: 'ignore', windowsHide: true});
  if (ready.status === 0) return;
  const status = spawnSync(path.join(config.pgBin, 'pg_ctl'), ['-D', dataDir, 'status'], {encoding: 'utf8', windowsHide: true});
  if (status.status === 0) return;
  // Windows server children can inherit captured pipes and keep spawnSync waiting.
  // Give the daemon no parent stdio handles; its output already goes to postgres.log.
  const started = spawnSync(path.join(config.pgBin, 'pg_ctl'), ['-D', dataDir, '-l', path.join(stateDir, 'postgres.log'), '-w', 'start'],
    {cwd: root, stdio: 'ignore', windowsHide: true, timeout: 30000});
  if (started.status !== 0) throw Error('Could not start project-local PostgreSQL. Inspect .local/postgres.log.');
  console.log('Project-local PostgreSQL started on 127.0.0.1:55432.');
}
export function stopPostgres() {
  const config = localConfig();
  console.log(run(path.join(config.pgBin, 'pg_ctl'), ['-D', path.join(stateDir, 'pgdata'), '-m', 'fast', '-w', 'stop']));
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.argv[2] === 'stop' ? stopPostgres() : startPostgres(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
