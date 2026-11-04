import {chromium} from '@playwright/test';
import {mkdirSync,writeFileSync} from 'node:fs';
import path from 'node:path';
import {root} from './python.mjs';

const browser=await chromium.launch({channel:'chrome',headless:true});
const output=path.join(root,'.local/preview');mkdirSync(output,{recursive:true});
const report=[];
try {
  const context=await browser.newContext({viewport:{width:1440,height:1000}});
  const page=await context.newPage();
  page.on('pageerror',error=>report.push({pageError:error.message}));
  await page.goto('http://127.0.0.1:5173/');
  await page.getByRole('heading',{name:'Welcome to the desk'}).waitFor();
  await page.screenshot({path:path.join(output,'login-desktop.png'),fullPage:true});
  const accounts=await (await context.request.get('http://127.0.0.1:5173/api/v1/dev/accounts')).json();
  for(const role of ['STUDENT','ADMIN']) {
    const account=accounts.find(a=>a.role===role);
    await context.request.post('http://127.0.0.1:5173/api/v1/auth/login',{data:{email:account.email,password:account.password}});
    await page.goto('http://127.0.0.1:5173/');
    await page.getByRole('heading',{name:role==='STUDENT'?'Your choices, in your order.':'Every seat, accounted for.'}).waitFor();
    for(const [name,width,height] of [['desktop',1440,1000],['mobile',390,844]]) {
      await page.setViewportSize({width,height});
      await page.screenshot({path:path.join(output,`${role.toLowerCase()}-${name}.png`),fullPage:true});
      report.push({role,viewport:name,...await page.evaluate(()=>({width:innerWidth,documentWidth:document.documentElement.scrollWidth,hasMain:!!document.querySelector('main#main')}))});
    }
  }
  await context.close();
} finally {await browser.close();}
writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2));
console.log(JSON.stringify(report,null,2));
if(report.some(r=>r.pageError||r.documentWidth>r.width))process.exitCode=1;
