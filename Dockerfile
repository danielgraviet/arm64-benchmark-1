FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY . .

ENV PATH="/app/.venv/bin:$PATH"
# Repo root first (v3 coding loop); sqlite-utils kept for legacy --task repo-agent-v2.
ENV PYTHONPATH="/app:/app/workload/repos/sqlite-utils"
ENV PYTHONHASHSEED=0

ENTRYPOINT ["python", "-m", "workload.agent"]
# Zen5 c=1 idle ~8s at --n 30 (see tickets/agent-v3-ladder.md). Re-check Vera when online.
CMD ["--n", "30", "--seed", "42"]
