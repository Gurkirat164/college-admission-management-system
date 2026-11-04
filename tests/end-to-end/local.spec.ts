import {test,expect} from '@playwright/test';

test('student can sign in, reorder and save real choices',async({page})=>{
 await page.goto('http://127.0.0.1:5173');
 await page.getByRole('button',{name:'Student',exact:true}).click();
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Your choices, in your order.'})).toBeVisible();
 await page.getByRole('button',{name:'Move ECE North Campus up',exact:true}).click();
 await page.getByRole('button',{name:'Save choices',exact:true}).click();
 await expect(page.getByRole('status')).toContainText('Your preference list was saved.');
 await page.reload();
 await expect(page.locator('.choice-list li').first()).toContainText('ECE');
 await page.getByRole('button',{name:'Move ECE North Campus down',exact:true}).click();
 await page.getByRole('button',{name:'Save choices',exact:true}).click();
 await page.getByRole('button',{name:'Sign out'}).click();
 await expect(page.getByRole('heading',{name:'Welcome to the desk'})).toBeVisible();
});

test('admin can run allocation and a what-if comparison',async({page})=>{
 await page.goto('http://127.0.0.1:5173');
 await page.getByRole('button',{name:'Admin',exact:true}).click();
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.getByRole('button',{name:'Run baseline',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Allocation results',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'What-if sandbox',exact:true}).click();
 await page.getByRole('button',{name:'Run scenario',exact:true}).click();
 await expect(page.getByRole('status')).toContainText('Scenario completed');
 await expect(page.getByRole('heading',{name:'What changed',exact:true})).toBeVisible();
});

test('admin uses mock jobs, import previews, round settings and final-admission screen',async({page})=>{
 await page.goto('http://127.0.0.1:5173');
 await page.getByRole('button',{name:'Admin',exact:true}).click();
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.getByText('Round deadlines and next-round setup',{exact:true}).click();
 await expect(page.getByRole('button',{name:'Save deadline',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Jobs & predictions',exact:true}).click();
 await page.getByRole('button',{name:'Run mock now',exact:true}).click();
 await expect(page.getByRole('status')).toContainText('Mock allotment completed');
 await expect(page.getByRole('heading',{name:'Job history'})).toBeVisible();
 await page.getByRole('button',{name:'Data imports',exact:true}).click();
 await page.getByLabel('Exam CSV',{exact:true}).setInputFiles('frontend/public/samples/exams.csv');
 await page.getByRole('button',{name:'Preview ranks',exact:true}).click();
 await expect(page.getByRole('status')).toContainText('No results were changed');
 await expect(page.getByRole('table',{name:'Rank preview',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Final admissions',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Confirm the final place.'})).toBeVisible();
});

test('student sees a real mock outcome and prediction freshness',async({page})=>{
 await page.goto('http://127.0.0.1:5173');
 await page.getByRole('button',{name:'Student',exact:true}).click();
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.getByRole('button',{name:'Your chances',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Latest mock allotment'})).toBeVisible();
 await expect(page.getByText('North Campus',{exact:false}).first()).toBeVisible();
 await expect(page.getByRole('table',{name:'Chance bands',exact:true})).toBeVisible();
 await expect(page.getByText('Prediction refresh:',{exact:false})).toBeVisible();
});

test('analyst can explore withdrawal controls and export a masked comparison',async({page})=>{
 await page.goto('http://127.0.0.1:5173');
 await page.getByRole('button',{name:'Analyst',exact:true}).click();
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.getByText('Program and student withdrawals',{exact:true}).click();
 await page.getByLabel('Student withdrawal rate (%)',{exact:true}).fill('10');
 await page.getByLabel('Reproducible seed',{exact:true}).fill('browser-fixture');
 await page.getByRole('button',{name:'Run scenario',exact:true}).click();
 await expect(page.getByRole('status')).toContainText('Scenario completed');
 await expect(page.getByRole('heading',{name:'Closing-rank shifts'})).toBeVisible();
 await expect(page.getByRole('heading',{name:'Possible vacancy links'})).toBeVisible();
 const downloadPromise=page.waitForEvent('download');
 await page.getByRole('link',{name:'Export masked CSV',exact:true}).click();
 const download=await downloadPromise;
 expect(download.suggestedFilename()).toMatch(/^simulation-\d+\.csv$/);
 await page.getByRole('button',{name:'Keep run',exact:true}).first().click();
 await expect(page.getByRole('status')).toContainText('pinned');
});

test('auditor can verify and browse the ledger',async({page})=>{
 await page.goto('http://127.0.0.1:5173');
 await page.getByRole('button',{name:'Auditor',exact:true}).click();
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.getByRole('button',{name:'Verify ledger',exact:true}).click();
 await expect(page.getByRole('status')).toContainText('Ledger verification completed');
 await expect(page.getByRole('heading',{name:'Recent audit events'})).toBeVisible();
 await expect(page.getByRole('table',{name:'Audit events',exact:true})).toBeVisible();
});
