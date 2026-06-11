# rl-guard 🛡️

**Rate Limit Guard** — plugin do Claude Code que bloqueia criação de novas tasks quando o limite diário de uso ultrapassa o threshold configurado.

Quando o limite está crítico (≥90%), o plugin faz o Claude Code **perguntar a você** antes de prosseguir — via prompt nativo, sem depender do modelo obedecer. Entre 80% e 90% ele apenas avisa o Claude para economizar.

## Como funciona

```
statusLine ─┐  rate_limits oficial → max(5h,7d) → /tmp/claude_rl_pct
(produtor)  │                                            │
            ▼                                            ▼
┌─────────────┐     ┌───────────────────────┐     ┌───────────────────────────────┐
│ TaskCreate  │ →   │ rl-guard (PreToolUse)  │ →   │ ≥ 90% → prompt nativo ("ask") │
│ (agente     │     │ lê /tmp/claude_rl_pct  │     │ ≥ 80% → nudge "economize"     │
│  principal) │     │                        │     │ < 80% → libera                │
└─────────────┘     └───────────────────────┘     └───────────────────────────────┘
```

- **Bloqueia** (≥ threshold) → emite `permissionDecision:"ask"` (JSON, exit 0) → o Claude Code te pergunta nativamente: continuar ou parar?
- **Avisa** (≥ warn, < threshold) → injeta `additionalContext` pedindo economia, sem bloquear
- **Libera** (< warn) → tudo normal, sem saída
- **Subagentes** são sempre liberados — só o agente principal é verificado
- **Fail-open** → cache ausente, velho (stale) ou com valor não-inteiro → libera

> **Nota:** o bloqueio agora usa o JSON nativo `permissionDecision:"ask"` (não mais `exit 2`). Requer uma versão do Claude Code que suporte os quatro resultados do `PreToolUse`. Em versões antigas o envelope é ignorado (fail-open).

## Automático (out-of-box)

A partir da v1.2 o plugin **funciona sozinho** — zero configuração. O `bin/install.sh` instala um produtor (`scripts/statusline-producer.sh`) e o liga como sua `statusLine`. Esse produtor lê o campo **oficial** `rate_limits.{five_hour,seven_day}.used_percentage` que o Claude Code já envia para a statusline, pega o `max` das duas janelas (arredondado), e escreve o inteiro em `/tmp/claude_rl_pct` — o cache que o guard consome. Nada de `ccusage`, estimativa, ou fonte sua.

**Preserva sua barra.** Se você já tem uma `statusLine`, o install **não sobrescreve**: ele guarda seu comando atual num sidecar (`~/.claude/plugins/rl-guard/.statusline-inner`), e o produtor o executa por baixo, repassando o stdin e imprimindo a saída dele igualzinha. Sua barra continua aparecendo; o produtor só adiciona a escrita do cache.

**Seguro e reversível.** O install faz backup do `settings.json` (`~/.claude/settings.json.rl-guard.bak`) antes de mexer, é idempotente (rodar de novo não duplica nada), e `bin/uninstall.sh` desfaz tudo — restaura sua `statusLine` original (ou remove a nossa se não havia uma) e desliga o plugin.

**Fail-open quando não há `rate_limits`.** Em planos/versões que não emitem o campo (API/console, Claude Code antigo), o produtor **não escreve nada** — o cache fica stale e o guard libera (no-op), exatamente como antes. A barra continua renderizando normalmente.

> **Requer `jq`** para o auto-wire (edição segura de JSON aninhado). Sem `jq`, o install não mexe no `settings.json` e imprime as instruções para você ligar a `statusLine` manualmente.

## Instalação

```bash
# Via npm (em breve)
npx rl-guard

# Via git
git clone https://github.com/xDisus/rl-guard.git ~/.claude/plugins/rl-guard
claude plugin enable rl-guard
```

Habilite no `settings.json`:
```json
{
  "enabledPlugins": {
    "rl-guard": true
  }
}
```

Reinicie a sessão do Claude Code (ou tmux).

## Configuração

| Variável | Default | Descrição |
|----------|---------|-----------|
| `RL_GUARD_THRESHOLD` | `90` | Percentual mínimo para **bloquear** (prompt nativo) |
| `RL_GUARD_WARN` | `80` | Percentual mínimo para **avisar** (sem bloquear) |
| `RL_GUARD_RESET` | `12:00 BRT` | Texto do horário de reset, mostrado no prompt |
| `RL_GUARD_STALE_MIN` | `10` | Minutos até o cache ser considerado velho (fail-open) |

```bash
# Exemplo: bloquear só aos 95%, avisar a partir de 85%, reset em UTC
RL_GUARD_THRESHOLD=95 RL_GUARD_WARN=85 RL_GUARD_RESET="09:00 UTC" claude
```

## Diagnóstico

No Claude Code, digite:

```
/rl-guard-doctor
```

Ou rode manualmente:
```bash
~/.claude/plugins/rl-guard/scripts/rl-guard-doctor.sh
```

Rode a matriz de testes completa:
```bash
bash ~/.claude/plugins/rl-guard/scripts/test.sh   # sai 0 se tudo passa
```

Teste o bloqueio manualmente — o guard emite JSON `permissionDecision:"ask"` e sai com **exit 0** (não mais `exit 2`):
```bash
echo 93 > /tmp/claude_rl_pct
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' \
  | ~/.claude/plugins/rl-guard/scripts/rate-limit-guard.sh
# stdout: {"hookSpecificOutput":{...,"permissionDecision":"ask",...}}  | exit 0
rm /tmp/claude_rl_pct
```

## Estrutura

```
~/.claude/plugins/rl-guard/
├── plugin.json                    — Manifesto do plugin
├── hooks/hooks.json               — Registro do hook PreToolUse
├── scripts/
│   ├── rate-limit-guard.sh        — Script principal do guard
│   ├── statusline-producer.sh     — Produtor: lê rate_limits oficial → cache
│   ├── rl-guard-doctor.sh         — Script de diagnóstico
│   ├── test.sh                    — Matriz de testes do guard
│   └── test-statusline.sh         — Matriz de testes do produtor + wiring
├── bin/
│   ├── install.sh                 — Instala + liga statusLine (preserva a sua)
│   └── uninstall.sh               — Desfaz o wiring (reversível)
├── commands/
│   └── rl-guard-doctor.md         — Slash command /rl-guard-doctor
├── .statusline-inner              — Sidecar: seu comando statusLine original
├── README.md
├── LICENSE
└── package.json
```

## Licença

MIT
