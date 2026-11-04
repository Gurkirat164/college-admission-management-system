import {spawnSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const python = path.join(root, '.venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!existsSync(python)) { console.error('Run npm run setup first.'); process.exit(1); }
  const result = spawnSync(python, process.argv.slice(2), {cwd: path.join(root, 'backend'), stdio: 'inherit'});
  process.exit(result.status ?? 1);
}
