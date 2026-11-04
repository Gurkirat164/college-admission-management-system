import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {root,python} from './python.mjs';
const config=JSON.parse(readFileSync(path.join(root,'.local/pg16/connection.json'),'utf8'));
const args=process.argv.slice(2);
const command=args[0]==='benchmark'?['-m','app.verification','--owner-url-env','VERIFY_OWNER_URL','--app-url-env','VERIFY_APP_URL']:['-m','pytest','tests','-q','--tb=short',...args];
const run=spawnSync(python,command,{cwd:path.join(root,'backend'),stdio:'inherit',env:{...process.env,MIGRATION_DATABASE_URL:config.owner_url,DATABASE_URL:config.app_url,VERIFY_OWNER_URL:config.owner_url,VERIFY_APP_URL:config.app_url},windowsHide:true});
process.exit(run.status??1);
