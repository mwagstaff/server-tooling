export type Action = 'none' | 'restart' | 'retry' | 'redeploy';
export type Service = {
  name: string; host: string; owner: string; unit: string; directory: string;
  logs: string[]; healthUrl: string; publicUrl?: string; runtimePort?: number;
  dependencies: string[]; autoActions: Action[]; approvalActions: Action[];
  group: string; scope?: string; adminHelper?: string;
};
export type Provider = {
  kind: 'ollama' | 'openai' | 'anthropic'; model: string; keyEnv?: string;
  baseUrl?: string; inputPerMillion: number; outputPerMillion: number;
  timeoutMs: number; maxOutputTokens: number; budgetUsd?: number; reasoningEffort?: 'medium';
};
export type Config = {
  host: string; listen: string; port: number; stateDir: string; publicUrl: string;
  dashboardPassword: string; webhookToken: string; peerToken?: string;
  peers: Record<string, string>; ssh: Record<string, {destination: string; runner: string}>;
  services: Service[]; providers: Provider[]; budgetUsd: number;
  automatic: boolean; cooldownSeconds: number; maxActions: number;
  alertmanagerUrl: string; prometheusUrl: string;
  verifyDelayMs: number; staleAfterMs: number;
  logs?: {url:string; token:string};
  notification: {pushoverUser?: string; pushoverToken?: string; smtpHost?: string;
    smtpPort?: number; smtpUser?: string; smtpPassword?: string; emailFrom?: string; emailTo?: string};
  queue?: {account: string; id: string; token: string};
};
export type Alert = {
  source: string; key: string; ref?: string; host: string; service: string; name: string;
  summary: string; status: 'firing' | 'resolved'; startsAt: string;
  labels: Record<string, string>; receivedAt: string;
};
export type Decision = {diagnosis: string; action: Action; reason: string; confidence: 'low' | 'medium' | 'high'};
export type Incident = {
  id: string; key: string; host: string; service: string; status: string;
  created: string; updated: string; alert: Alert; diagnosis: string;
  action?: Action; approvalExpires?: string; spent: number; attempts: number;
  runbook?: {id:string;version:number}; related?: {id:string;name:string;url:string}[];
  evidence?: any; verification?: any; resolvedAt?: string;
};
