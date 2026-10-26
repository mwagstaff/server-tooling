import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';

test('Sonnet escalation config selects dedicated key and preserves deployed vault value',()=>{
  const dir=mkdtempSync(join(tmpdir(),'aiops-config-'));
  try {
    writeFileSync(join(dir,'config.json'),JSON.stringify({host:'test',providers:[{
      kind:'anthropic',model:'claude-sonnet-5-5',keyEnv:'ANTHROPIC_API_KEY',timeoutMs:45000,maxOutputTokens:1500
    }]}));
    writeFileSync(join(dir,'secrets.env'),'ANTHROPIC_API_KEY=legacy-shared\nANTHROPIC_API_KEY_AIOPS=stale-private\n');
    const script=`import {loadConfig} from './lib/config.ts';
      const c=loadConfig();if(c.budgetUsd!==1||c.providers.length!==2||c.providers[0].budgetUsd!==0.2||c.providers[1].budgetUsd!==0.8||c.providers[1].reasoningEffort!=='medium')throw Error('Invalid policy');const p=c.providers[1];
      console.log(JSON.stringify({keyEnv:p.keyEnv,key:process.env[p.keyEnv],model:p.model}));`;
    const r=spawnSync(process.execPath,['--input-type=module','-e',script],{
      cwd:new URL('..',import.meta.url),encoding:'utf8',env:{...process.env,AIOPS_STATE_DIR:dir,
        AIOPS_CONFIG:join(dir,'config.json'),AIOPS_DASHBOARD_PASSWORD:'x'.repeat(30),
        AIOPS_WEBHOOK_TOKEN:'y'.repeat(30),ANTHROPIC_API_KEY_AIOPS:'current-vault'}
    });
    assert.equal(r.status,0,r.stderr);
    assert.deepEqual(JSON.parse(r.stdout),{keyEnv:'ANTHROPIC_API_KEY_AIOPS',key:'current-vault',model:'claude-sonnet-5-5'});
    writeFileSync(join(dir,'secrets.env'),'ANTHROPIC_API_KEY=legacy-shared\n');
    const env:NodeJS.ProcessEnv={...process.env,AIOPS_STATE_DIR:dir,AIOPS_CONFIG:join(dir,'config.json'),
      AIOPS_DASHBOARD_PASSWORD:'x'.repeat(30),AIOPS_WEBHOOK_TOKEN:'y'.repeat(30)};
    delete env.ANTHROPIC_API_KEY_AIOPS;
    const missing=spawnSync(process.execPath,['--input-type=module','-e',script],{
      cwd:new URL('..',import.meta.url),encoding:'utf8',env
    });
    assert.equal(missing.status,0,missing.stderr);
    assert.deepEqual(JSON.parse(missing.stdout),{keyEnv:'ANTHROPIC_API_KEY_AIOPS',model:'claude-sonnet-5-5'});
  } finally {rmSync(dir,{recursive:true,force:true});}
});

test('legacy Anthropic config selects dedicated key, takes priority, and never uses shared key',()=>{
  const dir=mkdtempSync(join(tmpdir(),'aiops-config-'));
  try {
    writeFileSync(join(dir,'config.json'),JSON.stringify({host:'test',providers:[{kind:'ollama',model:'qwen3.5:9b',timeoutMs:120000,maxOutputTokens:1500},{
      kind:'anthropic',model:'claude-haiku-4-5-20251001',keyEnv:'ANTHROPIC_API_KEY',timeoutMs:45000,maxOutputTokens:1500
    }]}));
    writeFileSync(join(dir,'secrets.env'),'ANTHROPIC_API_KEY=legacy-shared\nANTHROPIC_API_KEY_AIOPS=stale-private\n');
    const script=`import {loadConfig} from './lib/config.ts';
      const c=loadConfig();const p=c.providers[0];
      console.log(JSON.stringify({keyEnv:p.keyEnv,key:process.env[p.keyEnv],model:p.model}));`;
    const r=spawnSync(process.execPath,['--input-type=module','-e',script],{
      cwd:new URL('..',import.meta.url),encoding:'utf8',env:{...process.env,AIOPS_STATE_DIR:dir,
        AIOPS_CONFIG:join(dir,'config.json'),AIOPS_DASHBOARD_PASSWORD:'x'.repeat(30),
        AIOPS_WEBHOOK_TOKEN:'y'.repeat(30),ANTHROPIC_API_KEY_AIOPS:'current-vault'}
    });
    assert.equal(r.status,0,r.stderr);
    assert.deepEqual(JSON.parse(r.stdout),{keyEnv:'ANTHROPIC_API_KEY_AIOPS',key:'current-vault',model:'claude-haiku-4-5-20251001'});
    writeFileSync(join(dir,'secrets.env'),'ANTHROPIC_API_KEY=legacy-shared\n');
    const env:NodeJS.ProcessEnv={...process.env,AIOPS_STATE_DIR:dir,AIOPS_CONFIG:join(dir,'config.json'),
      AIOPS_DASHBOARD_PASSWORD:'x'.repeat(30),AIOPS_WEBHOOK_TOKEN:'y'.repeat(30)};
    delete env.ANTHROPIC_API_KEY_AIOPS;
    const missing=spawnSync(process.execPath,['--input-type=module','-e',script],{
      cwd:new URL('..',import.meta.url),encoding:'utf8',env
    });
    assert.equal(missing.status,0,missing.stderr);
    assert.deepEqual(JSON.parse(missing.stdout),{keyEnv:'ANTHROPIC_API_KEY_AIOPS',model:'claude-haiku-4-5-20251001'});
  } finally {rmSync(dir,{recursive:true,force:true});}
});
