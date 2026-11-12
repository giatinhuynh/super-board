# Agent hosts

super-board runs inside an agent host: the CLI whose session types `/super-board run`.
`scripts/super-board-host.sh` (installed as `.claude/bin/super-board-host.sh`) names it.

| Host value | Tested version | Start a run | Sign-in | Gaps |
|---|---|---|---|---|
| `claude` | Claude Code 2.1.302 | `/super-board run` (Workflow backend) | `claude` then `/login`; `gh auth login` | None. The reference host. |
| `codex` | codex-cli 0.160.0 | `/super-board run` inside Codex runs as `--codex`; from Claude, `/super-board run --codex` | `codex login`; `gh auth login` | No Workflow tool, so every lane is headless `codex exec`. Review runs only with explicit `--codex` (a host-switched plain `run` counts). No Claude usage guard. |
| `dsh` | DeepSeek Harness 0.2.2-rc.1 | From Claude Code: `/super-board run --dsh`. Inside a dsh session, plain `run` runs as `--dsh`. Each lane is `dsh headless`. | Add the model in the dsh web Models page. Put the provider in a patch file and set config `dsh.patch` to it. Export the key (e.g. `OLLAMA_API_KEY`) in the shell that starts the run: the headless profile does not read the web key store. `gh auth login` | No Workflow tool, so every lane is headless `dsh headless`. One model per run, no ladder, no router. The Claude hooks bridge is experimental: lanes do not rely on hooks. A person approves every merge. |
| `opencode` | OpenCode v2.0.22 | Not supported yet: the run halts with a host-selection request | `opencode auth login`; `gh auth login` | No OpenCode lane backend yet. `permission.external_directory: deny` is not enforced in v2.0.22 (`patch` still writes outside the repo), so OpenCode runs stay attended-only once a backend lands. |

Every host also needs `gh`, `jq`, bash 3.2+ and Python 3.9+.

## How the host is picked

`super-board-host.sh [--config <config.json>]` prints one value. First match wins:

1. `SUPER_BOARD_HOST=claude|codex|dsh|opencode`, the manual override. Any other value exits 64.
2. `CODEX_THREAD_ID` or `CODEX_SESSION_ID` → `codex`.
3. `DSH_SHELL` or `DSH_SESSION_ID` → `dsh`. dsh sets both in every bash tool call.
   `DSH_HOME` alone is ignored: people export it themselves.
4. `OPENCODE=1` → `opencode`. Checked before `CLAUDECODE`, which leaks into an OpenCode
   session started from Claude Code. `AGENT=1` is ignored: other tools set it too.
5. `CLAUDECODE` → `claude`.
6. The board config's top-level `host` key, when `--config` is given.
7. Nothing matched: empty stdout, a hint on stderr, exit 65. The run halts and asks for a
   host. It never guesses Claude.

A live env sign beats the saved config, so a Codex lane started from a Claude-configured
board still answers `codex`.

Onboard always writes `host` into `.claude/super-board/configs/<slug>.json`.
`super-board-setup.py fix` adds a missing one from `--host`; `check` flags any other value.

## DeepSeek Harness (dsh)

Each lane runs this command from the repo root, with the lane prompt on stdin:

```
dsh headless [--patch <dsh.patch>] [--patch <model pin>] \
  --permission-mode workspace-write --approval-policy never \
  --add-dir <git dir> [--add-dir <git common dir>] [--add-dir <dsh.add_dirs>...] -
```

- **Workspace.** dsh uses the current folder as its workspace. The lane starts it at the
  repo root, so worktrees under `.claude/worktrees/` are inside it.
- **Sandbox.** `workspace-write` blocks file writes outside the repo, the `--add-dir`
  folders and the temp folders. Reads and network are not blocked, so `gh` can reach
  GitHub and read its login. Add a folder to `dsh.add_dirs` when a tool must write to
  your home, e.g. `"~/.npm"` for `npm ci`.
- **Secrets.** dsh removes env names that contain `KEY`, `TOKEN`, `SECRET` or `PASSWORD`
  from its bash tool. `GH_TOKEN` does not reach `gh` there: sign in with `gh auth login`.
- **Model.** `dsh headless` has no model flag. `dsh.patch` (or `SUPER_BOARD_DSH_PATCH`)
  adds your provider. `--dsh=<provider>/<model>` or `dsh.model` pins one model for the run.
  An example patch for Ollama Cloud:

  ```yaml
  - id: llm-pi-ai
    name: "@deepseek-ai/dsh-llm-pi-ai"
    config:
      providers:
        ollama:
          displayName: Ollama Cloud
          apiKeyEnv: OLLAMA_API_KEY
          api: openai-completions
          baseURL: https://ollama.com/v1
          models:
            - id: deepseek-v4-pro
  - id: agent-default-model
    name: "@deepseek-ai/dsh-agent-default-model"
    config:
      provider: ollama
      model: deepseek-v4-pro
  ```
- **Skills.** dsh finds skills in `<repo>/.dsh/skills`, `<repo>/.agents/skills`,
  `~/.dsh/skills` and `~/.agents/skills`. install.sh already puts them in `.agents/skills`.
- **Bash timeout.** Each bash call stops after 60 seconds unless the model passes
  `timeoutMs`. The lane prompt tells it to do so for installs and test suites.
- **Merges.** `host: "dsh"` always waits for a person at the merge, even with
  `merge_policy.default: "auto"`.

## Evidence

- Codex: env of `codex exec -s read-only`, 2026-10-04 (recorded in the script header).
- OpenCode: env diff of an `opencode run` shell, 2026-10-19: `OPENCODE=1`,
  `OPENCODE_SESSION_ID`, `OPENCODE_TERMINAL=1`, `AGENT=1`.
- DeepSeek Harness: source of dsh 0.2.2-rc.1, 2026-11-12. `dsh-shell-env` sets `DSH_SHELL=1`,
  `DSH_SESSION_ID`, `DSH_HOME`, `DSH_PROFILE`, `DSH_PROFILE_DIR` in every bash call. Not yet
  seen in a live session: no model key was available.
