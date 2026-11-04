import {defineConfig} from '@playwright/test';
export default defineConfig({testDir:'tests/end-to-end',workers:1,retries:0,use:{headless:true,channel:'chrome',screenshot:'only-on-failure'},reporter:'list'});
