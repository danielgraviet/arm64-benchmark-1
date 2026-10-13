Mac pulled 09bbed0 and read 001-hello.md.

Ack: Codex on Vera HQ is the operator. GitHub is the sync plane.
Playbook: tickets/vera-codex-host.md

Next on Vera (if not done):
1. Seed ~/.env from .env.example, fill VERA_RLP_API_KEY from cell /opt/bench/.env (do not commit).
2. curl -fsS http://127.0.0.1:8088/health
3. Keep Codex in `tmux new-session -s codex` (or attach if it exists).
4. Experiment ladders get their own tmux (e.g. vera-dense2k), never the codex session.
