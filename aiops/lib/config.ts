import {readFileSync,mkdirSync,chmodSync,existsSync} from 'node:fs';
import {homedir} from 'node:os';
import type {Config} from './types.ts';

export function loadConfig(): Config {
  const stateDir=process.env.AIOPS_STATE_DIR || `${homedir()}/.local/share/aiops`;
  mkdirSync(stateDir,{recursive:true,mode:0o700});chmodSync(stateDir,0o700);
  if(existsSync(`${stateDir}/secrets.env`)) process.loadEnvFile(`${stateDir}/secrets.env`);
  const raw=JSON.parse(readFileSync(process.env.AIOPS_CONFIG || `${stateDir}/config.json`,'utf8'));
  const services=JSON.parse(readFileSync(new URL('../config/services.json',import.meta.url),'utf8'));
  const policy=JSON.parse(readFileSync(new URL('../config/model-policy.json',import.meta.url),'utf8'));
  const config:Config={
    listen:'127.0.0.1',port:19444,stateDir,publicUrl:'http://127.0.0.1:19444',
    peers:{},ssh:{},services,automatic:false,cooldownSeconds:900,maxActions:2,
    alertmanagerUrl:'http://127.0.0.1:19093',prometheusUrl:'http://127.0.0.1:19090',
    verifyDelayMs:15000,staleAfterMs:24*3600000,...raw,
    providers:policy.providers,budgetUsd:Math.min(raw.budgetUsd ?? policy.budgetUsd,policy.budgetUsd),
    dashboardPassword:process.env.AIOPS_DASHBOARD_PASSWORD || '',
    webhookToken:process.env.AIOPS_WEBHOOK_TOKEN || '',peerToken:process.env.AIOPS_PEER_TOKEN,
    notification:{
      pushoverUser:process.env.PUSHOVER_USER_KEY,pushoverToken:process.env.PUSHOVER_API_KEY_MONITORING,
      smtpHost:process.env.SMTP_HOST,smtpPort:Number(process.env.SMTP_PORT || 2587),
      smtpUser:process.env.SMTP_USER,smtpPassword:process.env.SMTP_PASSWORD,
      emailFrom:process.env.AIOPS_EMAIL_FROM || 'AIOps <alerts@skynolimit.dev>',
      emailTo:process.env.AIOPS_EMAIL_TO || 'mike.wagstaff@gmail.com'
    }
  };
  const loggingRoot=`${homedir()}/.local/share/server-tooling-monitoring`;
  if(existsSync(`${loggingRoot}/logging.json`) && existsSync(`${loggingRoot}/secrets/LOKI_TOKEN`)) {
    const logging=JSON.parse(readFileSync(`${loggingRoot}/logging.json`,'utf8'));
    config.logs={url:logging.url,token:readFileSync(`${loggingRoot}/secrets/LOKI_TOKEN`,'utf8').trim()};
  }
  if(process.env.CF_QUEUE_TOKEN && raw.queue) config.queue={...raw.queue,token:process.env.CF_QUEUE_TOKEN};
  else delete config.queue;
  if(!['mini','sky','test'].includes(config.host)) throw new Error('Invalid host identity');
  if(config.dashboardPassword.length<24 || config.webhookToken.length<24) throw new Error('Strong dashboard and webhook credentials required');
  if(!Number.isFinite(config.budgetUsd)||config.budgetUsd<0||config.budgetUsd>100) throw new Error('Invalid incident budget');
  if(!Array.isArray(config.providers)) throw new Error('Provider list required');
  for(const p of config.providers) {
    if(!['ollama','openai','anthropic'].includes(p.kind) || !p.model ||
      !(p.timeoutMs>=1000 && p.timeoutMs<=180000 && p.maxOutputTokens>0 && p.maxOutputTokens<=8192))
      throw new Error('Invalid provider configuration');
    if(p.budgetUsd!==undefined && (!Number.isFinite(p.budgetUsd)||p.budgetUsd<0||p.budgetUsd>1))
      throw new Error('Invalid provider budget');
    if(p.kind==='ollama' && !/^http:\/\/(?:127\.0\.0\.1|localhost):11434\/?$/.test(p.baseUrl || 'http://127.0.0.1:11434'))
      throw new Error('Local inference must use loopback');
  }
  return config;
}
