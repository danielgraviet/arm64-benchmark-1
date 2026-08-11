FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY rl ./rl

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONHASHSEED=0

ENTRYPOINT ["python", "-m", "rl.agent"]
CMD ["--n", "64"]
