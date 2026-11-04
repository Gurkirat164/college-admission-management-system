import {spawnSync} from 'node:child_process';
import {existsSync, writeFileSync, unlinkSync} from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {root, python} from './python.mjs';
import {initializePostgres, startPostgres, stateDir} from './local-db.mjs';

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {cwd: root, stdio: 'inherit', windowsHide: true, ...options});
  if (result.status !== 0) throw Error(`Setup stopped at ${path.basename(command)}. Existing data was retained.`);
}
try {
  if (!existsSync(python)) {
    const candidates = [process.env.ADMISSION_PYTHON, path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'), 'python3', 'python'];
    const runtime = candidates.find(p => p && spawnSync(p, ['-c', 'import sys; assert sys.version_info >= (3,11)'], {windowsHide: true, stdio: 'ignore'}).status === 0);
    if (!runtime) throw Error('Python 3.11+ is required. Set ADMISSION_PYTHON to its executable.');
    run(runtime, ['-m', 'venv', path.join(root, '.venv')]);
  }
  if (existsSync(path.join(root,'backend/requirements.lock.txt'))) {
    run(python, ['-m', 'pip', 'install', '--disable-pip-version-check', '-r', 'backend/requirements.lock.txt']);
  }
  run(python, ['-m', 'pip', 'install', '--disable-pip-version-check', '-e', './backend[dev]']);
  const npmCli = process.env.npm_execpath;
  if (npmCli) run(process.execPath, [npmCli, 'install', '--cache', path.join(root,'.local/npm-cache'), '--no-audit', '--no-fund']);
  const config = initializePostgres();
  startPostgres();
  const ownerURL = `postgresql://admission_owner:${config.ownerPassword}@127.0.0.1:${config.port}/admission`;
  const appURL = `postgresql://admission_app:${config.appPassword}@127.0.0.1:${config.port}/admission`;
  const envFile = path.join(root, 'backend/.env');
  if (!existsSync(envFile)) writeFileSync(envFile, `DATABASE_URL=${appURL}\nMIGRATION_DATABASE_URL=${ownerURL}\nAPP_ENV=development\nCOOKIE_SECURE=false\n`);
  run(python, ['-m', 'app.cli', 'bootstrap'], {cwd: path.join(root, 'backend')});
  const pwFile = path.join(stateDir, 'init-password');
  if (existsSync(pwFile)) unlinkSync(pwFile);
  console.log('Local setup ready. Run npm run dev.');
} catch (error) { console.error(error.message); process.exitCode = 1; }
