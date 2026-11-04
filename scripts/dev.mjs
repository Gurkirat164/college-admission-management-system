import {spawn} from 'node:child_process';
import path from 'node:path';
import {root, python} from './python.mjs';
import {startPostgres} from './local-db.mjs';
startPostgres();
const children = [
  spawn(python, ['-m','uvicorn','app.main:app','--host','127.0.0.1','--port','8000','--reload'], {cwd:path.join(root,'backend'),stdio:'inherit',windowsHide:true}),
  spawn(python, ['-m','app.jobs.worker','--watch'], {cwd:path.join(root,'backend'),stdio:'inherit',windowsHide:true}),
  spawn(process.execPath, [path.join(root,'node_modules/vite/bin/vite.js'),'--host','127.0.0.1','--port','5173','--strictPort'], {cwd:path.join(root,'frontend'),stdio:'inherit',windowsHide:true})
];
function stop() { children.forEach(child=>child.kill()); }
process.on('SIGINT', stop); process.on('SIGTERM', stop);
children.forEach(child=>child.on('exit',code=>{if(code)stop();}));
